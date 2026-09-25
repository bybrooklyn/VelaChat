import Foundation
import Observation
import VelaCore

/// Main-actor presentation state for the numeric-only usage ledger. The
/// SQLite actor remains the source of truth; this object owns only the current
/// period, loading/error state, and the last immutable report shown by SwiftUI.
@MainActor
@Observable
final class UsageDashboardModel {
    var period: UsagePeriod = .sevenDays
    private(set) var report: UsageReport?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private var refreshTask: Task<Void, Never>?
    private let ledger: UsageLedger

    init(ledger: UsageLedger = .shared) {
        self.ledger = ledger
    }

    func select(_ period: UsagePeriod) {
        guard self.period != period else { return }
        self.period = period
        refresh()
    }

    func refresh() {
        refreshTask?.cancel()
        let period = period
        let ledger = ledger
        isLoading = true
        errorMessage = nil
        refreshTask = Task { [weak self] in
            do {
                let report = try await ledger.query(UsageQuery(period: period))
                guard !Task.isCancelled else { return }
                self?.report = report
                self?.isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorMessage = error.localizedDescription
                self?.isLoading = false
            }
        }
    }

    func clearHistory() {
        refreshTask?.cancel()
        let ledger = ledger
        let period = period
        isLoading = true
        errorMessage = nil
        // Stamped before the wipe so a startup legacy migration still
        // assembling its source skips the import instead of resurrecting
        // these rows after the clear commits.
        Defaults.set(Date().timeIntervalSince1970, DefaultsKey.usageHistoryClearedAt)
        refreshTask = Task { [weak self] in
            do {
                try await ledger.clear()
                guard !Task.isCancelled else { return }
                let report = try await ledger.query(UsageQuery(period: period))
                guard !Task.isCancelled else { return }
                self?.report = report
                self?.isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorMessage = error.localizedDescription
                self?.isLoading = false
            }
        }
    }
}
