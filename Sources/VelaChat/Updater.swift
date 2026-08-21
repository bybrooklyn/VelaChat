import Foundation
import VelaCore
import Sparkle
import SwiftUI

/// Auto-update via Sparkle.
///
/// VelaChat is ad-hoc signed (no Apple Developer ID), which Sparkle
/// tolerates: it validates every update against an EdDSA public key
/// baked into Info.plist as `SUPublicEDKey`, independent of code
/// signing. The matching private key lives only in the repo's GitHub
/// secrets, so CI is the only thing that can publish a valid update.
///
/// Sparkle requires a real `.app` bundle and will not start without one.
/// `swift run` / `just run` executes the raw binary straight out of
/// `.build/debug/`, where there is no Info.plist — so no `SUFeedURL`, no
/// `SUPublicEDKey`, and none of Sparkle's XPC services. Starting the
/// updater there does not quietly no-op: `SPUStandardUpdaterController`
/// fails and puts a modal "Unable to Check For Updates — the updater
/// failed to start" alert on screen at launch, naming the host bundle as
/// "debug" (the enclosing directory) because that is all `Bundle.main`
/// can see. Gate on the same `isRunningAsBundledApp` latch that
/// `UNUserNotificationCenter` needs for the same reason, and leave the
/// updater inert during iteration.
@MainActor
@Observable
final class UpdaterController {
    /// `nil` when not running from a bundled `.app` — see the note above.
    private let controller: SPUStandardUpdaterController?
    private(set) var canCheckForUpdates = false
    private var observation: NSKeyValueObservation?

    /// Whether updating is possible at all in this launch context. Drives
    /// the explanatory copy in Settings, so a disabled control says why.
    var isAvailable: Bool { controller != nil }

    init() {
        guard AppModel.isRunningAsBundledApp else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor [weak self] in self?.canCheckForUpdates = value }
        }
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheckDescription: String {
        guard let controller else { return "Only available in the bundled app" }
        guard let date = controller.updater.lastUpdateCheckDate else { return "Never checked" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last checked \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }
}
