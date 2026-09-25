import SwiftUI
import Charts
import VelaCore

private enum UsageTrendMetric: String, CaseIterable, Identifiable {
    case tokens = "Tokens"
    case cost = "Cost"
    var id: String { rawValue }
}

/// Request-level usage, live provider limits, and the active context budget.
/// Historical numbers come from the content-free SQLite ledger, so deleting a
/// conversation cannot rewrite what was already used or spent.
struct StatisticsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var dashboard = UsageDashboardModel()
    @State private var trendMetric: UsageTrendMetric = .tokens
    @State private var editingContext = false
    @State private var contextText = ""
    @State private var confirmingClear = false

    var body: some View {
        SettingsPage {
            periodPanel
            if dashboard.isLoading, dashboard.report == nil {
                loadingPanel
            } else if let error = dashboard.errorMessage {
                errorPanel(error)
            } else if let report = dashboard.report {
                overviewPanel(report)
                trendPanel(report)
                liveLimitsPanel
                contextPanel
                breakdownPanel("Providers", symbol: "server.rack", items: report.providers, label: providerLabel)
                breakdownPanel("Models", symbol: "cpu", items: report.models) { $0.key ?? "Unknown model" }
                breakdownPanel("Request purpose", symbol: "arrow.triangle.branch", items: report.purposes) { purposeLabel($0.key) }
                recentPanel(report.recent)
                dataPanel(report)
            }
        }
        .task {
            dashboard.refresh()
            appModel.refreshActiveContextPreflight()
            if let provider = appModel.selectedProvider { appModel.refreshQuota(for: provider, force: true) }
        }
        .confirmationDialog("Clear usage history?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear Usage History", role: .destructive) { dashboard.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the numeric usage ledger. Conversations and messages are not changed.")
        }
    }

    private var periodPanel: some View {
        SettingsPanel(
            title: "Usage & Limits",
            symbol: "chart.bar.xaxis",
            footer: Text("Stored locally as numeric request telemetry only—never prompt or reply text.")
        ) {
            HStack(spacing: 6) {
                ForEach(UsagePeriod.allCases, id: \.rawValue) { period in
                    Button(periodTitle(period)) { dashboard.select(period) }
                        .buttonStyle(UsagePeriodButtonStyle(selected: dashboard.period == period))
                }
                Spacer(minLength: 8)
                if dashboard.isLoading { ProgressView().controlSize(.small) }
                Button { dashboard.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(VelaIconButtonStyle())
                    .help("Refresh usage")
                    .accessibilityLabel("Refresh usage")
            }
        }
    }

    private var loadingPanel: some View {
        SettingsPanel(title: "Loading usage", symbol: "arrow.triangle.2.circlepath") {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("Reading the local usage ledger…").foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private func errorPanel(_ error: String) -> some View {
        SettingsPanel(title: "Usage unavailable", symbol: "exclamationmark.triangle") {
            Text(error)
                .font(.callout)
                .foregroundStyle(Theme.warning)
                .textSelection(.enabled)
            Button("Try Again") { dashboard.refresh() }
                .buttonStyle(SettingsPrimaryButtonStyle())
        }
    }

    private func overviewPanel(_ report: UsageReport) -> some View {
        let aggregate = report.aggregate
        let legacyRequests = report.purposes.first(where: { $0.key == UsagePurpose.legacyAggregate.rawValue })?.aggregate.requestCount ?? 0
        let turnsValue = legacyRequests > 0
            ? (aggregate.turnCount > 0 ? "\(aggregate.turnCount)+" : "Unknown")
            : "\(aggregate.turnCount)"
        let turnsDetail = legacyRequests > 0
            ? "\(aggregate.requestCount) requests · legacy turns unavailable"
            : "\(aggregate.requestCount) actual requests"
        return SettingsPanel(title: "Overview", symbol: "gauge.with.needle", footer: Text(coverageDescription(aggregate.usageReporting))) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                UsageMetricTile(title: "Turns", value: turnsValue, detail: turnsDetail)
                UsageMetricTile(title: "Tokens", value: knownTotalTokens(aggregate).map(appModel.formattedTokenCount) ?? "Unknown", detail: tokenBreakdown(aggregate))
                UsageMetricTile(title: "Observed cost", value: costLabel(aggregate.cost), detail: coverageDescription(aggregate.cost.coverage))
                UsageMetricTile(title: "Cache", value: aggregate.cacheReadTokens.value.map(appModel.formattedTokenCount) ?? "Unknown", detail: "read · \(aggregate.cacheWriteTokens.map(appModel.formattedTokenCount) ?? "unknown") written")
            }
        }
    }

    private func trendPanel(_ report: UsageReport) -> some View {
        SettingsPanel(title: "Trend", symbol: "chart.xyaxis.line") {
            Picker("Metric", selection: $trendMetric) {
                ForEach(UsageTrendMetric.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if report.trend.isEmpty {
                SettingsEmptyState(text: "No recorded requests in this period.", symbol: "chart.xyaxis.line")
            } else {
                Chart(report.trend) { point in
                    if trendMetric == .tokens {
                        BarMark(x: .value("Day", point.day, unit: .day), y: .value("Tokens", knownTotalTokens(point.aggregate) ?? 0))
                            .foregroundStyle(Theme.accent.gradient)
                    } else {
                        LineMark(x: .value("Day", point.day, unit: .day), y: .value("Cost", point.aggregate.cost.amountUSD ?? 0))
                            .foregroundStyle(Theme.accent)
                            .interpolationMethod(.catmullRom)
                        PointMark(x: .value("Day", point.day, unit: .day), y: .value("Cost", point.aggregate.cost.amountUSD ?? 0))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(Theme.separator.opacity(0.35))
                        AxisValueLabel {
                            if trendMetric == .cost, let amount = value.as(Double.self) {
                                Text(amount, format: .currency(code: "USD").precision(.fractionLength(0...2)))
                            } else if let tokens = value.as(Int.self) {
                                Text(appModel.formattedTokenCount(tokens))
                            }
                        }
                    }
                }
                .frame(minHeight: 180, idealHeight: 220, maxHeight: 300)
                .accessibilityLabel("\(trendMetric.rawValue) trend for \(periodTitle(report.query.period))")
            }
        }
    }

    private var liveLimitsPanel: some View {
        SettingsPanel(title: "Live provider limits", symbol: "hourglass", footer: Text("Provider-reported limits are separate from the local ledger.")) {
            if let provider = appModel.selectedProvider {
                HStack(spacing: 8) {
                    ProviderLogoView(kind: provider.kind, endpoint: provider.endpoint, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(provider.name).font(.callout.weight(.semibold))
                        Text(appModel.currentModelID.isEmpty ? "Provider default" : appModel.currentModelID)
                            .font(.caption2).foregroundStyle(Theme.tertiaryText)
                    }
                    Spacer()
                    Button("Refresh") { appModel.refreshQuota(for: provider, force: true) }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                }
                if let quota = appModel.quotaByProvider[provider.id] {
                    if let plan = quota.planName { SettingsValueRow("Plan", plan) }
                    if let primary = quota.primaryWindow { quotaWindow(primary) }
                    if let secondary = quota.secondaryWindow { quotaWindow(secondary) }
                    if let remaining = quota.requestsRemaining {
                        SettingsValueRow("Requests remaining", quota.requestsLimit.map { "\(remaining) of \($0)" } ?? "\(remaining)")
                    }
                    if let remaining = quota.tokensRemaining {
                        SettingsValueRow("Tokens remaining", quota.tokensLimit.map { "\(remaining) of \($0)" } ?? "\(remaining)")
                    }
                    Text("Observed \(quota.capturedAt, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(Date().timeIntervalSince(quota.capturedAt) > 7_200 ? Theme.warning : Theme.tertiaryText)
                } else {
                    SettingsEmptyState(text: "No provider-reported quota is available yet.", symbol: "hourglass")
                }
            } else {
                SettingsEmptyState(text: "Choose a provider to inspect its limits.", symbol: "server.rack")
            }
        }
    }

    private var contextPanel: some View {
        SettingsPanel(
            title: "Context capacity",
            symbol: "circle.dotted",
            footer: Text(appModel.contextEstimateIsCalibrated
                ? "Calibrated from provider-reported usage; exact preflight counts replace it when supported."
                : "A fallback estimate until provider evidence or an exact preflight count is available.")
        ) {
            let used = appModel.contextTokenEstimate
            if let window = appModel.contextWindow {
                let usable = appModel.activeContextBudget?.usableInputTokens ?? window
                SettingsValueRow(appModel.contextEstimateIsExact ? "Provider-counted input" : "Estimated input", appModel.formattedTokenCount(used), tint: used > usable ? Theme.danger : nil)
                SettingsValueRow("Resolved limit", appModel.formattedTokenCount(window))
                SettingsValueRow("Usable input", appModel.formattedTokenCount(usable))
                SettingsValueRow("Remaining", appModel.formattedTokenCount(usable - used), tint: used > usable ? Theme.danger : nil)
                if let source = appModel.contextEvidenceSource { SettingsValueRow("Evidence", source.label) }
                if let reserve = appModel.activeContextBudget?.requestedOutputTokens, reserve > 0 {
                    SettingsValueRow("Output reserved", appModel.formattedTokenCount(reserve))
                }
                ProgressView(value: min(max(Double(used) / Double(max(usable, 1)), 0), 1))
                    .tint(used > usable ? Theme.danger : (Double(used) / Double(max(usable, 1)) > 0.8 ? Theme.warning : Theme.accent))
                if used > usable {
                    Text("Prepared input exceeds the usable budget by \(appModel.formattedTokenCount(used - usable)) tokens.")
                        .font(.caption).foregroundStyle(Theme.danger)
                }
            } else {
                SettingsEmptyState(text: "No trustworthy context limit is known for this endpoint and model.", symbol: "questionmark.circle")
            }
            if let error = appModel.activeContextPreflightError {
                Text("Exact count unavailable; using the local estimate. \(error)")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            contextLimitEditor
        }
    }

    @ViewBuilder private var contextLimitEditor: some View {
        if editingContext {
            HStack(spacing: 7) {
                TextField("Context tokens", text: $contextText)
                    .textFieldStyle(.plain).flatFieldStyle().frame(maxWidth: 180)
                Button("Set") {
                    appModel.setContextWindowOverride(Int(contextText.filter(\.isNumber)))
                    editingContext = false
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .disabled(Int(contextText.filter(\.isNumber)) == nil)
                Button("Cancel") { editingContext = false }.buttonStyle(SettingsSecondaryButtonStyle())
                Spacer()
            }
        } else {
            HStack {
                Button(appModel.contextWindow == nil ? "Set context limit" : "Correct limit") {
                    contextText = appModel.contextWindow.map(String.init) ?? ""
                    editingContext = true
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                if appModel.contextWindowIsOverridden {
                    Button("Reset to automatic") { appModel.setContextWindowOverride(nil) }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                }
                Spacer()
            }
        }
    }

    private func breakdownPanel(_ title: String, symbol: String, items: [UsageBreakdown], label: @escaping (UsageBreakdown) -> String) -> some View {
        SettingsPanel(title: title, symbol: symbol) {
            if items.isEmpty {
                SettingsEmptyState(text: "No breakdown is available for this period.", symbol: symbol)
            } else {
                ForEach(items.prefix(12)) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(label(item)).font(.callout.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(breakdownValue(item.aggregate)).font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func recentPanel(_ records: [RequestUsage]) -> some View {
        SettingsPanel(title: "Recent requests", symbol: "clock.arrow.circlepath", footer: Text("One row per provider request, including tool rounds and auxiliary work.")) {
            if records.isEmpty {
                SettingsEmptyState(text: "No request records in this period.", symbol: "clock")
            } else {
                ForEach(records.prefix(20)) { record in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.effectiveModelID ?? record.requestedModelID ?? "Unknown model").font(.callout.weight(.medium)).lineLimit(1)
                            Text("\(purposeLabel(record.purpose.rawValue)) · \(record.occurredAt, style: .relative) ago")
                                .font(.caption2).foregroundStyle(Theme.tertiaryText)
                        }
                        Spacer(minLength: 8)
                        Text(requestValue(record)).font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func dataPanel(_ report: UsageReport) -> some View {
        SettingsPanel(title: "Usage data", symbol: "internaldrive") {
            SettingsValueRow("Ledger records", "\(report.aggregate.recordCount)")
            SettingsValueRow("Database", UsageLedger.defaultDatabaseURL.lastPathComponent)
            Button("Clear Usage History…", role: .destructive) { confirmingClear = true }
                .buttonStyle(SettingsDestructiveButtonStyle())
        }
    }

    @ViewBuilder private func quotaWindow(_ window: QuotaSnapshot.Window) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label).font(.caption.weight(.medium))
                Spacer()
                Text("\(Int(window.usedPercent))% used").font(.caption).foregroundStyle(Theme.secondaryText)
            }
            ProgressView(value: min(max(window.usedPercent / 100, 0), 1)).tint(window.usedPercent > 80 ? Theme.warning : Theme.accent)
            if let resetAt = window.resetAt { Text("Resets \(resetAt, style: .relative)").font(.caption2).foregroundStyle(Theme.tertiaryText) }
        }
    }

    private func knownTotalTokens(_ aggregate: UsageAggregate) -> Int? {
        guard aggregate.inputTokens.value != nil || aggregate.outputTokens.value != nil else { return nil }
        return (aggregate.inputTokens.value ?? 0) + (aggregate.outputTokens.value ?? 0)
    }

    private func tokenBreakdown(_ aggregate: UsageAggregate) -> String {
        "\(aggregate.inputTokens.value.map(appModel.formattedTokenCount) ?? "?") in · \(aggregate.outputTokens.value.map(appModel.formattedTokenCount) ?? "?") out"
    }

    /// A total that doesn't cover every request is a lower bound, labeled
    /// as one — the retired meter's `≥` rule, kept for the new dashboard.
    private func qualifiedCost(_ cost: UsageCostTotal) -> String? {
        guard let amount = cost.amountUSD else { return nil }
        let partial = cost.coverage.indeterminateRequests > 0 || cost.coverage.unreportedRequests > 0
        return (partial ? "≥ " : "") + String(format: "$%.4f", amount)
    }

    private func costLabel(_ cost: UsageCostTotal) -> String {
        qualifiedCost(cost) ?? "Unknown"
    }

    private func coverageDescription(_ coverage: UsageReportingCoverage) -> String {
        guard coverage.totalRequests > 0 else { return "No requests recorded in this period." }
        if let exact = coverage.exactFraction { return "Provider usage reported for \(Int((exact * 100).rounded()))% of requests." }
        let minimum = Int(((coverage.minimumFraction ?? 0) * 100).rounded())
        return "Provider usage reported for at least \(minimum)% of requests; legacy coverage is indeterminate."
    }

    private func breakdownValue(_ aggregate: UsageAggregate) -> String {
        let tokens = knownTotalTokens(aggregate).map(appModel.formattedTokenCount) ?? "unknown tokens"
        let cost = qualifiedCost(aggregate.cost)
        return "\(aggregate.requestCount) req · \(tokens)" + (cost.map { " · \($0)" } ?? "")
    }

    private func requestValue(_ record: RequestUsage) -> String {
        let total = record.inputTokens == nil && record.outputTokens == nil ? nil : (record.inputTokens ?? 0) + (record.outputTokens ?? 0)
        return (total.map(appModel.formattedTokenCount) ?? "usage unreported")
            + (record.cost.map { String(format: " · $%.4f", $0.amountUSD) } ?? "")
    }

    private func providerLabel(_ item: UsageBreakdown) -> String {
        guard let key = item.key, let id = UUID(uuidString: key) else { return "Unknown provider" }
        return appModel.providers.profile(id: id)?.name ?? "Removed provider"
    }

    private func purposeLabel(_ raw: String?) -> String {
        guard let raw, let purpose = UsagePurpose(rawValue: raw) else { return "Unknown purpose" }
        switch purpose {
        case .chat: return "Chat"
        case .toolRound: return "Tool round"
        case .autoContinue: return "Auto-continue"
        case .title: return "Conversation title"
        case .compaction: return "Context compaction"
        case .handoff: return "Handoff"
        case .subagent: return "Subagent"
        case .legacyAggregate: return "Legacy aggregate"
        }
    }

    private func periodTitle(_ period: UsagePeriod) -> String {
        switch period {
        case .today: return "Today"
        case .sevenDays: return "7 days"
        case .thirtyDays: return "30 days"
        case .allTime: return "All time"
        }
    }
}

private struct UsageMetricTile: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(Theme.tertiaryText)
            Text(value).font(.title3.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
            Text(detail).font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.surfaceMid, in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
        .velaBorder(RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous), emphasis: 0.35)
    }
}

private struct UsagePeriodButtonStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(selected ? Theme.accentForeground : Theme.secondaryText)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(selected ? Theme.accentStrong : Theme.surfaceHigh, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
