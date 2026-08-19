import Foundation
import Sparkle
import SwiftUI

/// Auto-update via Sparkle.
///
/// VelaChat is ad-hoc signed (no Apple Developer ID), which Sparkle
/// tolerates: it validates every update against an EdDSA public key
/// baked into Info.plist as `SUPublicEDKey`, independent of code
/// signing. The matching private key lives only in the repo's GitHub
/// secrets, so CI is the only thing that can publish a valid update.
@MainActor
@Observable
final class UpdaterController {
    private let controller: SPUStandardUpdaterController
    private(set) var canCheckForUpdates = false
    private var observation: NSKeyValueObservation?

    init() {
        // `startingUpdater: true` is safe here — Sparkle no-ops when the
        // feed or key is missing (a source build without them) rather
        // than failing loudly at launch.
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor [weak self] in self?.canCheckForUpdates = value }
        }
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheckDescription: String {
        guard let date = controller.updater.lastUpdateCheckDate else { return "Never checked" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last checked \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
