import Foundation
import Observation

private struct CachedModelCatalog: Codable {
    let models: [RemoteModel]
    let fetchedAt: Date
}

@MainActor
@Observable
final class ProviderStore {
    enum Status: Equatable {
        case idle
        case connecting
        case connected(String)
        case connectedEmpty(String)
        case failed(String)
    }

    private let defaults = UserDefaults.standard
    private let profilesKey = "velachat.provider-profiles"
    private let selectedKey = "velachat.selected-provider"
    private let explicitSelectionKey = "velachat.explicit-provider-selection"
    private let catalogsKey = "velachat.model-catalogs"
    private let contextOverridesKey = "velachat.context-window-overrides"

    var profiles: [ProviderProfile] = []
    /// Manual context-window corrections, keyed by `"<providerID>|<modelID>"`
    /// — for the many catalogs that don't publish a context length at all,
    /// or a custom/self-hosted endpoint whose real limit VelaChat has no way
    /// to discover on its own. Set from the context popover in the composer.
    private(set) var contextWindowOverrides: [String: Int] = [:] {
        didSet {
            defaults.set(contextWindowOverrides, forKey: contextOverridesKey)
        }
    }
    var selectedID: UUID
    var statusByID: [UUID: Status] = [:]
    var modelsByID: [UUID: [RemoteModel]] = [:]
    var refreshedAtByID: [UUID: Date] = [:]

    struct PullState: Equatable {
        var status: String
        var fraction: Double?
        var errorMessage: String?
        var isDone = false
    }
    /// Keyed by Ollama model name — a pull isn't tied to a conversation, so
    /// this lives here rather than on any one view's local state, letting
    /// the Providers screen and Settings both reflect the same in-flight pull.
    var pullState: [String: PullState] = [:]
    private var pullTasks: [String: Task<Void, Never>] = [:]
    var codexCredential: CodexCredential?
    var codexMessage: String?
    /// Key presence per profile — see `hasStoredKey(for:)`.
    private(set) var hasKeyByID: [UUID: Bool] = [:]

    private var didStartDiscovery = false
    private var discoveryTasks: [UUID: Task<Void, Never>] = [:]
    private var catalogCache: [UUID: CachedModelCatalog] = [:]
    private let refreshInterval: TimeInterval = 15 * 60

    init() {
        let loadedProfiles: [ProviderProfile]
        if let data = defaults.data(forKey: profilesKey),
           let saved = try? JSONDecoder().decode([ProviderProfile].self, from: data),
           !saved.isEmpty {
            loadedProfiles = saved
        } else {
            loadedProfiles = ProviderProfile.defaults()
        }

        let repairedProfiles = loadedProfiles.map { profile in
            var migrated = profile
            if ModelCatalog.isLegacyAutomaticModel(migrated.model) {
                migrated.model = ""
            }
            // DeepSeek’s current API base is /, not /v1. Preserve custom
            // endpoints but repair the built-in value from earlier builds.
            if migrated.kind == .deepSeek, migrated.endpoint == "https://api.deepseek.com/v1" {
                migrated.endpoint = "https://api.deepseek.com"
            }
            return migrated
        }
        // Newly added built-in providers have to be merged into an existing
        // saved list, otherwise anyone who has run VelaChat before would keep
        // only the providers that existed on their first launch.
        var merged = repairedProfiles
        for preset in ProviderProfile.defaults() where preset.kind.isBuiltIn {
            guard !merged.contains(where: { $0.kind == preset.kind }) else { continue }
            merged.append(preset)
        }
        let migratedProfiles = merged
        profiles = migratedProfiles
        let persistedID = defaults.string(forKey: selectedKey).flatMap(UUID.init(uuidString:))
        selectedID = persistedID.flatMap { id in
            migratedProfiles.contains(where: { $0.id == id }) ? id : nil
        } ?? migratedProfiles.first?.id ?? ProviderProfile.defaults()[0].id
        restoreCatalogs()
        contextWindowOverrides = defaults.dictionary(forKey: contextOverridesKey) as? [String: Int] ?? [:]
        refreshCodex()
        saveProfiles()
        // Deliberately *not* primed here. Keychain calls can block on a
        // system prompt, and this initializer runs before the window exists —
        // blocking here meant the app launched to no window at all.
        Task { [weak self] in self?.primeKeyCache() }
    }

    var selected: ProviderProfile? {
        profiles.first { $0.id == selectedID }
    }

    /// Whether a provider has a stored key, answered from an in-memory cache.
    ///
    /// This must never reach the Keychain directly: SwiftUI re-evaluates view
    /// bodies constantly, and a per-row `SecItemCopyMatching` meant Settings
    /// issued dozens of synchronous Keychain calls per layout pass — enough to
    /// block the main thread hard enough that the window never appeared.
    func hasStoredKey(for id: UUID) -> Bool {
        hasKeyByID[id] ?? false
    }

    /// True once at least one real (non-Preview) provider is actually usable:
    /// a hosted provider with a stored key, or a local server that has really
    /// answered with a model catalog. A keyless local provider that isn't
    /// running must not count, or Preview would vanish on a fresh install and
    /// leave the app with nothing that works.
    var hasConfiguredRealProvider: Bool {
        profiles.contains(where: isConfigured)
    }

    /// True for a real (non-Preview) provider that's actually usable right
    /// now: a hosted provider with a stored key, a keyless remote provider
    /// like blockrun.ai (always usable — nothing to configure), or a local
    /// server that has really answered with a model catalog. A keyless
    /// local provider that isn't running must not count, or it would show
    /// as "configured" with nothing behind it.
    func isConfigured(_ profile: ProviderProfile) -> Bool {
        guard profile.kind != .preview else { return false }
        if profile.kind.requiresKey {
            if profile.kind == .codex, codexCredential != nil { return true }
            return hasStoredKey(for: profile.id)
        }
        if profile.kind.isLocal {
            return !(modelsByID[profile.id] ?? []).isEmpty
        }
        return true
    }

    /// Reads each profile's key presence once, so views can ask freely after.
    private func primeKeyCache() {
        for profile in profiles where profile.kind.requiresKey {
            hasKeyByID[profile.id] = !(SecureStore.value(for: keychainAccount(profile.id)) ?? "").isEmpty
        }
    }

    func select(_ id: UUID, markExplicit: Bool = true) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        selectedID = id
        defaults.set(id.uuidString, forKey: selectedKey)
        if markExplicit {
            defaults.set(true, forKey: explicitSelectionKey)
        }
        discoverIfNeeded(id: id)
    }

    /// Resolve a useful provider on first launch instead of treating the
    /// offline preview as the answer to every setup. A deliberate provider
    /// choice is always respected afterwards.
    func start() {
        guard !didStartDiscovery else { return }
        didStartDiscovery = true

        let hasExplicitChoice = defaults.bool(forKey: explicitSelectionKey)
        guard !hasExplicitChoice, selected?.kind == .preview else {
            discoverIfNeeded(id: selectedID)
            return
        }

        if let codex = profiles.first(where: { $0.kind == .codex }), codexCredential != nil {
            select(codex.id)
            return
        }
        if let configured = profiles.first(where: { profile in
            profile.kind != .preview && hasStoredKey(for: profile.id)
        }) {
            select(configured.id)
            return
        }
        // Try local servers first (if one's actually running, nothing leaves
        // this Mac), then a keyless remote fallback like blockrun.ai — a real
        // working connection beats leaving a fresh install on canned Preview
        // replies.
        let autoTryProfiles = profiles.filter { $0.kind.isLocal } + profiles.filter { $0.kind == .blockrun }
        if !autoTryProfiles.isEmpty {
            Task { [weak self] in
                guard let self else { return }
                for candidate in autoTryProfiles {
                    await self.refreshModels(id: candidate.id)
                    if case .connected = self.status(for: candidate.id) {
                        self.select(candidate.id)
                        return
                    }
                }
                self.discoverIfNeeded(id: self.selectedID)
            }
            return
        }
        discoverIfNeeded(id: selectedID)
    }

    func hasDiscoveredModels(for id: UUID) -> Bool {
        guard modelsByID[id] != nil else { return false }
        if case .failed = statusByID[id] { return false }
        return true
    }

    func isDiscovering(id: UUID) -> Bool {
        statusByID[id] == .connecting
    }

    func discoverIfNeeded(id: UUID) {
        guard let profile = profile(id: id), profile.kind != .preview else {
            if profile(id: id)?.kind == .preview {
                modelsByID[id] = [RemoteModel(id: "preview", name: "Preview", supportsReasoning: false)]
                refreshedAtByID[id] = Date()
                statusByID[id] = .connected("Offline preview")
            }
            return
        }
        selectRecommendedModelIfNeeded(id: id)
        let isFresh = refreshedAtByID[id].map { Date().timeIntervalSince($0) < refreshInterval } ?? false
        guard !isFresh else { return }
        _ = discoveryTask(for: id)
    }

    func ensureReady(id: UUID) async -> ProviderProfile? {
        guard let profile = profile(id: id) else { return nil }
        if profile.kind != .preview, modelsByID[id] == nil || statusByID[id].map(isFailed) == true {
            await discoveryTask(for: id).value
        }
        return self.profile(id: id)
    }

    /// Reuses any discovery already in flight for this provider instead of
    /// firing a duplicate request — rapid provider switching or repeated
    /// `ensureReady`/`discoverIfNeeded` calls should never race each other.
    @discardableResult
    private func discoveryTask(for id: UUID) -> Task<Void, Never> {
        if let existing = discoveryTasks[id] { return existing }
        statusByID[id] = .connecting
        let task = Task { [weak self] in
            await self?.refreshModels(id: id, autoSelect: true)
            self?.discoveryTasks[id] = nil
        }
        discoveryTasks[id] = task
        return task
    }

    func profile(id: UUID) -> ProviderProfile? {
        profiles.first { $0.id == id }
    }

    func update(id: UUID, endpoint: String? = nil, model: String? = nil, name: String? = nil) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        if let endpoint, profiles[index].endpoint != endpoint {
            profiles[index].endpoint = endpoint
            invalidateCatalog(for: id)
        }
        if let model { profiles[index].model = model }
        if let name { profiles[index].name = name }
        saveProfiles()
    }

    /// Creates without selecting — adding an endpoint you haven't finished
    /// configuring must never silently become the app's active provider.
    func createCompatible(name: String, endpoint: String) -> UUID {
        let fallbackName = "Custom endpoint \(profiles.filter { $0.kind == .compatible }.count + 1)"
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = ProviderProfile(
            kind: .compatible,
            name: trimmedName.isEmpty ? fallbackName : trimmedName,
            endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        profiles.append(profile)
        saveProfiles()
        return profile.id
    }

    func remove(id: UUID) {
        guard let profile = profile(id: id), profile.kind == .compatible else { return }
        profiles.removeAll { $0.id == id }
        SecureStore.set(nil, for: keychainAccount(id))
        hasKeyByID[id] = nil
        modelsByID[id] = nil
        refreshedAtByID[id] = nil
        catalogCache[id] = nil
        persistCatalogs()
        statusByID[id] = nil
        if selectedID == id, let replacement = profiles.first {
            selectedID = replacement.id
        }
        saveProfiles()
    }

    func apiKey(for id: UUID) -> String {
        SecureStore.value(for: keychainAccount(id)) ?? ""
    }

    @discardableResult
    func setAPIKey(_ key: String, for id: UUID) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = SecureStore.set(trimmed, for: keychainAccount(id))
        hasKeyByID[id] = saved && !trimmed.isEmpty
        invalidateCatalog(for: id)
        return saved
    }

    func credential(for profile: ProviderProfile) -> ProviderCredential {
        if profile.kind == .codex, let codexCredential {
            return ProviderCredential(token: codexCredential.token, accountID: codexCredential.accountID, isCodexOAuth: !codexCredential.isAPIKey)
        }
        let key = apiKey(for: profile.id)
        return ProviderCredential(token: key.isEmpty ? nil : key, accountID: nil, isCodexOAuth: false)
    }

    func status(for id: UUID) -> Status {
        statusByID[id] ?? .idle
    }

    func models(for id: UUID) -> [RemoteModel] {
        modelsByID[id] ?? []
    }

    func modelInfo(for id: UUID, model: String? = nil) -> RemoteModel? {
        guard let profile = profile(id: id) else { return nil }
        let requestedModel = model ?? profile.model
        guard !requestedModel.isEmpty else { return nil }
        return modelsByID[id]?.first(where: { $0.id == requestedModel })
    }

    private func contextOverrideKey(providerID: UUID, model: String) -> String {
        "\(providerID.uuidString)|\(model)"
    }

    func contextWindowOverride(providerID: UUID, model: String) -> Int? {
        guard !model.isEmpty else { return nil }
        return contextWindowOverrides[contextOverrideKey(providerID: providerID, model: model)]
    }

    /// Pass `nil` to clear a correction and fall back to auto-detection again.
    func setContextWindowOverride(_ value: Int?, providerID: UUID, model: String) {
        guard !model.isEmpty else { return }
        let key = contextOverrideKey(providerID: providerID, model: model)
        if let value, value > 0 {
            contextWindowOverrides[key] = value
        } else {
            contextWindowOverrides.removeValue(forKey: key)
        }
    }

    func selectedModelInfo(for id: UUID) -> RemoteModel? {
        modelInfo(for: id)
    }

    func thinkingLevels(for id: UUID, model: String? = nil) -> [ThinkingLevel] {
        guard let profile = profile(id: id) else { return [.auto] }
        if let selectedModel = modelInfo(for: id, model: model) {
            return selectedModel.thinkingLevels(for: profile.kind)
        }
        let requestedModel = model ?? profile.model
        let fallback = requestedModel.isEmpty
            ? ModelCatalog.automaticModel(for: profile.kind)
            : RemoteModel(id: requestedModel)
        return fallback.thinkingLevels(for: profile.kind)
    }

    func automaticModel(for id: UUID) -> RemoteModel {
        guard let profile = profile(id: id) else {
            return ModelCatalog.automaticModel(for: .compatible)
        }
        return selectedModelInfo(for: id) ?? ModelCatalog.automaticModel(for: profile.kind)
    }

    /// Returns the ID used on the wire. A provider that does not publish a
    /// catalog still gets a sensible provider-specific fallback automatically.
    func effectiveModel(for profile: ProviderProfile) -> String {
        if !profile.model.isEmpty { return profile.model }
        return ModelCatalog.automaticModel(for: profile.kind).id
    }

    func isUsingAutomaticModel(for id: UUID) -> Bool {
        guard let profile = profile(id: id) else { return true }
        return profile.model.isEmpty || selectedModelInfo(for: id) == nil
    }

    func refreshCodex() {
        codexCredential = CodexAuth.discover()
        if let codexCredential {
            codexMessage = "Codex login found · \(codexCredential.kindLabel)"
        }
    }

    func launchCodexLogin() {
        do {
            try CodexAuth.launchLogin()
            codexMessage = "Codex login opened in a terminal. Finish it there, then return here."
            Task { [weak self] in
                for _ in 0..<90 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    if let credential = CodexAuth.discover() {
                        self?.codexCredential = credential
                        self?.codexMessage = "Codex connected · \(credential.kindLabel)"
                        return
                    }
                }
            }
        } catch {
            codexMessage = error.localizedDescription
        }
    }

    func test(id: UUID) async {
        guard let profile = profile(id: id) else { return }
        if profile.kind == .preview {
            statusByID[id] = .connected("Offline preview ready")
            return
        }
        await refreshModels(id: id, autoSelect: true)
    }

    /// Pulls a new Ollama model, tracking live progress in `pullState` so
    /// any view can show it, and refreshes the catalog once it lands so the
    /// new model shows up in the picker without a manual refresh.
    func pullModel(id: UUID, name: String) {
        guard let profile = profile(id: id), profile.kind == .ollama else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, pullState[trimmed] == nil else { return }
        pullState[trimmed] = PullState(status: "Starting…", fraction: nil)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await progress in CompatibleChatClient.shared.pullOllamaModel(profile: profile, name: trimmed) {
                    try Task.checkCancellation()
                    let fraction: Double? = {
                        guard let total = progress.total, total > 0, let completed = progress.completed else { return nil }
                        return min(1, max(0, Double(completed) / Double(total)))
                    }()
                    self.pullState[trimmed] = PullState(status: progress.status, fraction: fraction)
                }
                self.pullState[trimmed] = PullState(status: "Done", fraction: 1, isDone: true)
                self.pullTasks.removeValue(forKey: trimmed)
                await self.refreshModels(id: id)
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if self.pullState[trimmed]?.isDone == true {
                    self.pullState.removeValue(forKey: trimmed)
                }
            } catch is CancellationError {
                self.pullTasks.removeValue(forKey: trimmed)
            } catch {
                self.pullState[trimmed] = PullState(status: "", fraction: nil, errorMessage: error.localizedDescription)
                self.pullTasks.removeValue(forKey: trimmed)
            }
        }
        pullTasks[trimmed] = task
    }

    /// Actually cancels the in-flight download (not just the UI state) —
    /// Ollama stops writing to disk once the client disconnects.
    func cancelPull(name: String) {
        pullTasks[name]?.cancel()
        pullTasks.removeValue(forKey: name)
        pullState.removeValue(forKey: name)
    }

    func refreshModels(id: UUID, autoSelect: Bool = true) async {
        guard let profile = profile(id: id), profile.kind != .preview else {
            if profile(id: id)?.kind == .preview {
                modelsByID[id] = [RemoteModel(id: "preview", name: "Preview")]
                refreshedAtByID[id] = Date()
                statusByID[id] = .connected("Offline preview ready")
            }
            return
        }

        statusByID[id] = .connecting
        do {
            let models = try await fetchModelsWithRetry(profile: profile)
            modelsByID[id] = models
            refreshedAtByID[id] = Date()
            catalogCache[id] = CachedModelCatalog(models: models, fetchedAt: Date())
            persistCatalogs()
            // An empty profile gets a one-time recommended model. Once the
            // user has selected an exact ID, discovery must never replace it
            // behind their back—even if a provider’s catalog is incomplete.
            if autoSelect,
               profile.model.isEmpty,
               let selected = ModelCatalog.bestModel(for: profile, models: models),
               let index = profiles.firstIndex(where: { $0.id == id }) {
                profiles[index].model = selected.id
                saveProfiles()
            }
            if models.isEmpty {
                statusByID[id] = .connectedEmpty("Connected · no models found")
            } else {
                statusByID[id] = .connected("Connected · \(models.count) models")
            }
        } catch {
            modelsByID[id] = nil
            refreshedAtByID[id] = nil
            statusByID[id] = .failed(error.localizedDescription)
        }
    }

    /// Local/self-hosted endpoints (Ollama, LM Studio, vLLM…) are commonly
    /// slow to warm up. A single transient failure shouldn't strand the
    /// provider in `.failed` until the user manually retries.
    private func fetchModelsWithRetry(profile: ProviderProfile) async throws -> [RemoteModel] {
        func attempt() async throws -> [RemoteModel] {
            if profile.kind == .codex && credential(for: profile).isCodexOAuth {
                return ModelCatalog.curated(for: .codex)
            }
            return try await CompatibleChatClient.shared.fetchModels(profile: profile, credential: credential(for: profile))
        }
        do {
            return try await attempt()
        } catch {
            // A 4xx (bad/missing key, wrong path, malformed request) will
            // never succeed on retry — waiting 1.5s just to fail again the
            // same way doubled how long a wrong key took to report itself.
            // Only genuinely transient failures (network hiccups, 5xx, a
            // local server still warming up) get the retry.
            if case APIError.status(let code, _) = error, (400..<500).contains(code) {
                throw error
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return try await attempt()
        }
    }

    func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: profilesKey)
        }
    }

    /// Full-reset support: removes every stored API key, then rebuilds the
    /// default profiles from scratch (fresh IDs are fine — the keys are
    /// gone on purpose) and clears every cache.
    func performFullReset() {
        for profile in profiles {
            _ = SecureStore.set(nil, for: keychainAccount(profile.id))
        }
        profiles = ProviderProfile.defaults()
        modelsByID = [:]
        statusByID = [:]
        hasKeyByID = [:]
        refreshedAtByID = [:]
        catalogCache = [:]
        if let first = profiles.first?.id { selectedID = first }
        saveProfiles()
    }

    func resetBuiltIns() {
        let custom = profiles.filter { $0.kind == .compatible }
        // Reuses each built-in's existing ID rather than the fresh random one
        // `ProviderProfile.defaults()` mints, because Keychain entries are
        // keyed by ID — minting new ones orphaned every stored API key on
        // reset, silently and irreversibly, despite the confirmation dialog
        // promising only endpoint and model values would change.
        let existingIDs = Dictionary(uniqueKeysWithValues: profiles.map { ($0.kind, $0.id) })
        let resetPresets = ProviderProfile.defaults().map { preset in
            ProviderProfile(
                id: existingIDs[preset.kind] ?? preset.id,
                kind: preset.kind,
                name: preset.name,
                endpoint: preset.endpoint,
                model: preset.model,
                enabled: preset.enabled
            )
        }
        profiles = resetPresets + custom
        modelsByID.removeAll()
        refreshedAtByID.removeAll()
        catalogCache.removeAll()
        persistCatalogs()
        statusByID.removeAll()
        if !profiles.contains(where: { $0.id == selectedID }), let first = profiles.first {
            selectedID = first.id
        }
        saveProfiles()
        discoverIfNeeded(id: selectedID)
    }

    private func isFailed(_ status: Status) -> Bool {
        if case .failed = status { return true }
        return false
    }

    private func selectRecommendedModelIfNeeded(id: UUID) {
        guard let profile = profile(id: id), profile.model.isEmpty,
              let cachedModels = modelsByID[id],
              let selected = ModelCatalog.bestModel(for: profile, models: cachedModels),
              let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].model = selected.id
        saveProfiles()
    }

    private func invalidateCatalog(for id: UUID) {
        modelsByID[id] = nil
        refreshedAtByID[id] = nil
        catalogCache[id] = nil
        persistCatalogs()
        statusByID[id] = .idle
    }

    private func restoreCatalogs() {
        guard let data = defaults.data(forKey: catalogsKey),
              let saved = try? JSONDecoder().decode([String: CachedModelCatalog].self, from: data) else { return }
        for (key, value) in saved {
            guard let id = UUID(uuidString: key), profiles.contains(where: { $0.id == id }) else { continue }
            catalogCache[id] = value
            modelsByID[id] = value.models
            refreshedAtByID[id] = value.fetchedAt
            statusByID[id] = value.models.isEmpty
                ? .connectedEmpty("Cached · no models found")
                : .connected("Cached · \(value.models.count) models")
            if let profile = profile(id: id), profile.model.isEmpty,
               let selected = ModelCatalog.bestModel(for: profile, models: value.models),
               let index = profiles.firstIndex(where: { $0.id == id }) {
                profiles[index].model = selected.id
            }
        }
    }

    private func persistCatalogs() {
        let saved = Dictionary(uniqueKeysWithValues: catalogCache.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: catalogsKey)
        }
    }

    private func keychainAccount(_ id: UUID) -> String {
        "provider-\(id.uuidString)"
    }
}
