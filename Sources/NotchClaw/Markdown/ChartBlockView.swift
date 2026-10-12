import Charts
import SwiftUI

/// A chart the agent describes as JSON inside a ```chart fence.
///
///     {"type": "bar|line|area|point|pie", "title": "…", "x": "label", "y": "label", "unit": "$",
///      "data": [{"x": "Mon", "y": 3, "series": "optional"}]}
struct ChartSpec: Equatable {
    enum Kind: String { case bar, line, area, point, pie }

    struct Point: Equatable, Identifiable {
        var id: Int
        var x: String
        var xNumber: Double?
        var y: Double
        var series: String?
    }

    var kind: Kind
    var title: String?
    var xLabel: String?
    var yLabel: String?
    var unit: String?
    var points: [Point]

    var hasSeries: Bool { points.contains { $0.series != nil } }
    var numericX: Bool { !points.isEmpty && points.allSatisfy { $0.xNumber != nil } }

    static func parse(_ source: String) -> ChartSpec? {
        guard let json = try? JSON.decode(Data(source.utf8)) else { return nil }
        let rows = json["data"]?.array ?? json["points"]?.array ?? json.array ?? []
        let points: [Point] = rows.enumerated().compactMap { index, row in
            let xValue = row["x"] ?? row["label"] ?? row["name"] ?? row["category"]
            let yValue = row["y"] ?? row["value"] ?? row["count"]
            guard let y = yValue?.double else { return nil }
            let xText = xValue?.string ?? xValue?.double.map { $0.formatted() } ?? "\(index + 1)"
            return Point(id: index, x: xText, xNumber: xValue?.string == nil ? xValue?.double : nil, y: y,
                         series: row["series"]?.text ?? row["group"]?.text)
        }
        guard !points.isEmpty else { return nil }
        let kind = Kind(rawValue: (json["type"]?.string ?? json["kind"]?.string ?? "bar").lowercased()) ?? .bar
        return ChartSpec(
            kind: kind, title: json["title"]?.text, xLabel: json["x"]?.text ?? json["xLabel"]?.text,
            yLabel: json["y"]?.text ?? json["yLabel"]?.text, unit: json["unit"]?.text, points: points)
    }
}

struct ChartBlockView: View {
    let source: String
    let size: CGFloat
    var isStreaming = false

    var body: some View {
        if let spec = ChartSpec.parse(source) {
            ChartCard(spec: spec, size: size)
        } else if isStreaming {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Drawing chart…").font(.system(size: size - 1)).foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        } else {
            CodeBlockView(language: "chart", code: source, size: size - 1.5)
        }
    }
}

private struct ChartCard: View {
    let spec: ChartSpec
    let size: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = spec.title {
                Text(title)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
            chart
                .frame(height: spec.kind == .pie ? 190 : 170)
                .chartLegend(spec.hasSeries || spec.kind == .pie ? .visible : .hidden)
                .chartForegroundStyleScale(range: NotchPalette.chartColors)
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spec.title ?? "Chart")
    }

    @ViewBuilder
    private var chart: some View {
        let xName = spec.xLabel ?? "x"
        let yName = spec.yLabel ?? "y"
        if spec.kind == .pie {
            Chart(spec.points) { point in
                SectorMark(angle: .value(yName, point.y), innerRadius: .ratio(0.55), angularInset: 1.5)
                    .foregroundStyle(by: .value(xName, point.x))
                    .cornerRadius(3)
            }
        } else {
            Chart(spec.points) { point in
                mark(for: point, x: xName, y: yName)
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.06))
                    AxisValueLabel().foregroundStyle(.white.opacity(0.55))
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.08))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("\(spec.unit ?? "")\(v.formatted(.number.notation(.compactName)))")
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }
            }
            .chartXAxisLabel(spec.xLabel ?? "", alignment: .trailing)
            .chartYAxisLabel(spec.yLabel ?? "")
        }
    }

    @ChartContentBuilder
    private func mark(for point: ChartSpec.Point, x: String, y: String) -> some ChartContent {
        let series = point.series ?? (spec.hasSeries ? "—" : y)
        switch spec.kind {
        case .line:
            LineMark(x: .value(x, point.x), y: .value(y, point.y))
                .foregroundStyle(by: .value("Series", series))
                .interpolationMethod(.catmullRom)
                .symbol(.circle)
        case .area:
            AreaMark(x: .value(x, point.x), y: .value(y, point.y))
                .foregroundStyle(by: .value("Series", series))
                .interpolationMethod(.catmullRom)
                .opacity(0.75)
        case .point:
            PointMark(x: .value(x, point.x), y: .value(y, point.y))
                .foregroundStyle(by: .value("Series", series))
        case .bar, .pie:
            BarMark(x: .value(x, point.x), y: .value(y, point.y))
                .foregroundStyle(by: .value("Series", spec.hasSeries ? series : point.x))
                .cornerRadius(4)
        }
    }
}

extension NotchPalette {
    static let chartColors: [Color] = [
        Color(red: 0.55, green: 0.42, blue: 1.0),
        Color(red: 0.25, green: 0.75, blue: 1.0),
        Color(red: 1.0, green: 0.36, blue: 0.62),
        Color(red: 0.3, green: 0.88, blue: 0.62),
        Color(red: 1.0, green: 0.7, blue: 0.25),
        Color(red: 0.95, green: 0.95, blue: 1.0),
    ]
}
