import Foundation
import VelaCore
import Observation

@MainActor
@Observable
final class RedactionStore {
    var isEnabled: Bool {
        didSet { Defaults.set(isEnabled, DefaultsKey.redactionEnabled) }
    }
    private(set) var rules: [RedactionRule] = [] {
        didSet { persist() }
    }

    init() {
        isEnabled = Defaults.bool(DefaultsKey.redactionEnabled, default: true)
        if let data = UserDefaults.standard.data(forKey: DefaultsKey.redactionRules),
           let saved = try? JSONDecoder().decode([RedactionRule].self, from: data), !saved.isEmpty {
            // Built-ins added in a later version have to appear for users
            // who already have a saved set, or new protections would only
            // ever reach fresh installs.
            var merged = saved
            let knownNames = Set(saved.filter(\.isBuiltIn).map(\.name))
            for builtIn in RedactionRule.builtIns() where !knownNames.contains(builtIn.name) {
                merged.append(builtIn)
            }
            rules = merged
        } else {
            rules = RedactionRule.builtIns()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.redactionRules)
        }
    }

    var redactor: Redactor { Redactor(rules: isEnabled ? rules : []) }

    var invalidRuleIDs: Set<UUID> { Redactor.invalidRuleIDs(in: rules) }

    func add(name: String, pattern: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPattern.isEmpty else { return }
        rules.append(RedactionRule(name: trimmedName, pattern: trimmedPattern))
    }

    func update(_ rule: RedactionRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].isEnabled = enabled
    }

    /// Built-ins are disabled, never removed — see `RedactionRule.isBuiltIn`.
    func delete(_ id: UUID) {
        rules.removeAll { $0.id == id && !$0.isBuiltIn }
    }

    func restoreBuiltIns() {
        let custom = rules.filter { !$0.isBuiltIn }
        rules = RedactionRule.builtIns() + custom
    }
}
