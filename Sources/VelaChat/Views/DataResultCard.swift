import SwiftUI
import Charts
import VelaCore

/// §9.2 — a `query_data` result in the transcript: the rows as a real
/// table, and the chart the model asked for underneath.
///
/// Follows `StatisticsView`'s visual language rather than calling it —
/// that view is 197 lines of hand-built SwiftUI with no generic chart to
/// point a result at. Charts here are Apple's Swift `Charts`, which is
/// exactly this use case; `StatisticsView` is deliberately left alone.
struct DataResultCard: View {
    let outcome: DataQueryOutcome
    @State private var isExpanded = true
    @State private var showingSQL = false

    /// Rows shown before the table becomes its own scroll area. Enough to
    /// see the shape of the answer without a 200-row result pushing the
    /// reply off screen.
    private let collapsedRowCount = 8

    private var numericColumns: Set<Int> {
        var numeric: Set<Int> = []
        for index in outcome.columns.indices {
            let values = outcome.rows.compactMap { $0.indices.contains(index) ? $0[index] : nil }
            let hasNumber = values.contains { if case .null = $0 { return false } else if case .text = $0 { return false } else { return true } }
            let hasText = values.contains { if case .text = $0 { return true } else { return false } }
            if hasNumber && !hasText { numeric.insert(index) }
        }
        return numeric
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isExpanded {
                if showingSQL {
                    Text(outcome.sql)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surfaceMid, in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
                }
                table
                if let chart = outcome.chart {
                    DataResultChart(spec: chart, columns: outcome.columns, rows: outcome.rows)
                        .frame(height: 200)
                        .padding(.top, 2)
                }
                if let problem = outcome.chartProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(Theme.warning)
                }
            }
        }
        .padding(11)
        .messageColumn()
        .background(Theme.surfaceLow, in: RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous))
        .velaBorder(RoundedRectangle(cornerRadius: Theme.Radius.compact, style: .continuous), emphasis: 0.4)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "tablecells")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.secondaryText)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Button {
                withAnimation(.easeOut(duration: 0.16)) { showingSQL.toggle() }
            } label: {
                Text("SQL")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(showingSQL ? Theme.accent : Theme.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("Show the query that produced this")
            .accessibilityLabel(showingSQL ? "Hide the query" : "Show the query")
        }
    }

    private var title: String {
        let count = outcome.rows.count
        var text = "\(count) row\(count == 1 ? "" : "s")"
        if outcome.truncated { text += " (capped)" }
        if let chartTitle = outcome.chart?.title, !chartTitle.isEmpty { text = chartTitle + " · " + text }
        return text
    }

    private var table: some View {
        let numeric = numericColumns
        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    ForEach(Array(outcome.columns.enumerated()), id: \.offset) { index, column in
                        Text(column)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.tertiaryText)
                            .frame(minWidth: 54, alignment: numeric.contains(index) ? .trailing : .leading)
                    }
                }
                .padding(.bottom, 4)
                Divider().opacity(0.4)
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(outcome.rows.enumerated()), id: \.offset) { rowIndex, row in
                            HStack(spacing: 14) {
                                ForEach(Array(outcome.columns.enumerated()), id: \.offset) { index, _ in
                                    let value = index < row.count ? row[index] : DataValue.null
                                    Text(value.isNull ? "—" : value.displayText)
                                        .font(.system(size: 11, design: numeric.contains(index) ? .monospaced : .default))
                                        .foregroundStyle(value.isNull ? Theme.tertiaryText : Theme.text)
                                        .lineLimit(1)
                                        .frame(minWidth: 54, alignment: numeric.contains(index) ? .trailing : .leading)
                                }
                            }
                            .padding(.vertical, 3)
                            .background(rowIndex.isMultiple(of: 2) ? Color.clear : Theme.surfaceMid.opacity(0.5))
                        }
                    }
                }
                .frame(maxHeight: outcome.rows.count > collapsedRowCount ? 220 : nil)
            }
        }
    }
}

/// The chart half. The spec's `type` chooses the mark — the renderer never
/// re-infers one from the data, because the model already decided and the
/// contract carries that decision.
struct DataResultChart: View {
    let spec: DataAnalysis.ChartSpec
    let columns: [String]
    let rows: [[DataValue]]

    private struct Point: Identifiable {
        let id = UUID()
        var category: String
        var numeric: Double?
        var y: Double
        var series: String
    }

    private var points: [Point] {
        guard let xIndex = columns.firstIndex(of: spec.xField),
              let yIndex = columns.firstIndex(of: spec.yField) else { return [] }
        let seriesIndex = spec.series.flatMap { columns.firstIndex(of: $0) }
        var built: [Point] = []
        for row in rows {
            guard xIndex < row.count, yIndex < row.count else { continue }
            // A row whose y isn't a number has nothing to plot; skipping it
            // is honest, where coercing it to zero would draw a value the
            // data never contained.
            guard let y = number(row[yIndex]) else { continue }
            let x = row[xIndex]
            built.append(Point(
                category: x.isNull ? "—" : x.displayText,
                numeric: number(x),
                y: y,
                series: seriesIndex.flatMap { $0 < row.count ? row[$0].displayText : nil } ?? ""
            ))
        }
        switch spec.sort {
        case .xAscending: built.sort { sortKey($0) < sortKey($1) }
        case .xDescending: built.sort { sortKey($0) > sortKey($1) }
        case .yAscending: built.sort { $0.y < $1.y }
        case .yDescending: built.sort { $0.y > $1.y }
        case nil: break
        }
        if let limit = spec.limit, built.count > limit {
            built = Array(built.prefix(limit))
        }
        return built
    }

    /// Numeric x sorts numerically; everything else sorts as text. Sorting
    /// "10" before "9" is the classic way an ordered chart lies.
    private func sortKey(_ point: Point) -> String {
        guard let numeric = point.numeric else { return point.category }
        return String(format: "%020.6f", numeric)
    }

    private func number(_ value: DataValue) -> Double? {
        switch value {
        case .integer(let number): return Double(number)
        case .number(let number): return number
        case .text(let text): return Double(text.trimmingCharacters(in: .whitespaces))
        case .null: return nil
        }
    }

    private var xLabel: String { spec.xLabel ?? spec.xField }
    private var yLabel: String { spec.yLabel ?? spec.yField }

    var body: some View {
        let data = points
        if data.isEmpty {
            Text("Nothing in this result could be plotted.")
                .font(.caption2)
                .foregroundStyle(Theme.tertiaryText)
        } else if data.allSatisfy({ $0.numeric != nil }) {
            // A numeric x-axis is a real scale (gaps between 1 and 100 look
            // like gaps), not evenly spaced labels.
            Chart(data) { point in
                marks(x: .value(xLabel, point.numeric ?? 0), point: point)
            }
            .chartStyling(yLabel: yLabel, hasSeries: spec.series != nil)
        } else {
            Chart(data) { point in
                marks(x: .value(xLabel, point.category), point: point)
            }
            .chartStyling(yLabel: yLabel, hasSeries: spec.series != nil)
        }
    }

    @ChartContentBuilder
    private func marks<X: Plottable>(x: PlottableValue<X>, point: Point) -> some ChartContent {
        switch spec.type {
        case .bar:
            BarMark(x: x, y: .value(yLabel, point.y))
                .foregroundStyle(by: .value("Series", point.series.isEmpty ? yLabel : point.series))
        case .line:
            LineMark(x: x, y: .value(yLabel, point.y))
                .foregroundStyle(by: .value("Series", point.series.isEmpty ? yLabel : point.series))
                .symbol(Circle().strokeBorder(lineWidth: 1.5))
        case .scatter:
            PointMark(x: x, y: .value(yLabel, point.y))
                .foregroundStyle(by: .value("Series", point.series.isEmpty ? yLabel : point.series))
        case .area:
            AreaMark(x: x, y: .value(yLabel, point.y))
                .foregroundStyle(by: .value("Series", point.series.isEmpty ? yLabel : point.series))
                .opacity(0.65)
        }
    }
}

private extension View {
    /// One place for the chart chrome, so both x-axis branches above can
    /// never drift apart visually.
    func chartStyling(yLabel: String, hasSeries: Bool) -> some View {
        self
            .chartForegroundStyleScale(range: DataChartPalette.colors)
            .chartLegend(hasSeries ? .visible : .hidden)
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Theme.separator.opacity(0.4))
                    AxisTick().foregroundStyle(Theme.separator)
                    AxisValueLabel()
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Theme.separator.opacity(0.4))
                    AxisValueLabel()
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
    }
}

/// Series colours: the app's accent first, then hues that stay distinct
/// from each other and from the transcript's own surfaces.
enum DataChartPalette {
    static var colors: [Color] {
        [Theme.accent, Theme.modelAccent, Theme.coral, Theme.reasoningAccent, Theme.success, Theme.warning]
    }
}
