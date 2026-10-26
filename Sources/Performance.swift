import AppKit
import SwiftUI
import Charts

enum HistoryRange: String, CaseIterable, Identifiable {
    case fiveMinutes = "5m", thirtyMinutes = "30m", hour = "1h", sixHours = "6h"
    case day = "24h", threeDays = "3d", week = "7d"
    var id: String { rawValue }
    var duration: TimeInterval {
        switch self {
        case .fiveMinutes: return 300
        case .thirtyMinutes: return 1800
        case .hour: return 3600
        case .sixHours: return 21600
        case .day: return 86400
        case .threeDays: return 259200
        case .week: return 604800
        }
    }
}

struct MetricValues: Decodable {
    let cpu: Double?
    let memory: Double?
    let gpu: Double?
}

struct HistoryPoint: Decodable, Identifiable {
    let timestamp: Double
    let cpu: Double?
    let memory: Double?
    let gpu: Double?
    let processes: Int
    let run: String?
    var id: Double { timestamp }
    var date: Date { Date(timeIntervalSince1970: timestamp) }
}

struct HistoryReply: Decodable {
    let id: String
    let range: String
    let start: Double
    let end: Double
    let resolution: Double
    let recording_since: Double?
    let running: Bool?
    let points: [HistoryPoint]
    let latest: HistoryPoint?
    let peaks: MetricValues

    func sample(near date: Date) -> HistoryPoint? {
        let time = date.timeIntervalSince1970
        guard let nearest = points.min(by: { abs($0.timestamp - time) < abs($1.timestamp - time) }),
              abs(nearest.timestamp - time) <= max(60, resolution) * 1.25 else { return nil }
        if abs(nearest.timestamp - time) < 0.001 { return nearest }
        if let before = points.last(where: { $0.timestamp < time }),
           let after = points.first(where: { $0.timestamp > time }), before.run != after.run {
            return nil
        }
        return nearest
    }
}

final class PerformanceMonitor: ObservableObject {
    @Published var range: HistoryRange = .fiveMinutes {
        didSet { if range != oldValue { history = nil; loadHistory() } }
    }
    @Published private(set) var history: HistoryReply?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private let helper: Helper.Caller
    private var identifier: String?
    private var timer: Timer?
    private var interval: TimeInterval?
    private var visible = false
    private var sampling = false
    private var lastSample = Date.distantPast
    private var generation = 0

    init(helper: @escaping Helper.Caller = Helper.call) { self.helper = helper }

    func select(_ id: String?) {
        identifier = id
        history = nil
        generation += 1
        loading = false
        if id != nil { loadHistory(); sample() }
    }
    func setSampling(focused: Bool) {
        visible = focused
        let next: TimeInterval = focused ? 15 : 60
        guard interval != next else { return }
        interval = next
        timer?.invalidate()
        let timer = Timer(timeInterval: next, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func stop() { timer?.invalidate(); timer = nil }
    func sample() {
        guard !sampling, Date().timeIntervalSince(lastSample) >= 5 else { return }
        sampling = true
        helper(["sample", "--interval", interval == 15 ? "15" : "60"], nil) { result in
            self.sampling = false
            switch result {
            case .success:
                self.lastSample = Date()
                self.error = nil
                if self.visible && self.identifier != nil { self.loadHistory() }
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }
    func loadHistory() {
        guard let identifier else { return }
        generation += 1
        let requested = generation
        loading = true
        helper(["history", identifier, "--range", range.rawValue], nil) { result in
            guard requested == self.generation else { return }
            self.loading = false
            switch result {
            case .success(let data):
                do { self.history = try JSONDecoder().decode(HistoryReply.self, from: data); self.error = nil }
                catch { self.error = error.localizedDescription }
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }
}

enum MetricKind: String, CaseIterable {
    case cpu = "CPU", memory = "Memory", gpu = "GPU"
    var color: Color {
        switch self { case .cpu: return .blue; case .memory: return .purple; case .gpu: return .mint }
    }
    var icon: String {
        switch self { case .cpu: return "cpu"; case .memory: return "memorychip"; case .gpu: return "square.3.layers.3d" }
    }
    var help: String {
        switch self {
        case .cpu: return "CPU time across the service and its running child processes. 100% equals one CPU core."
        case .memory: return "Physical memory footprint of the service and its running child processes, including compressed memory."
        case .gpu: return "Per-process Metal execution time divided by elapsed time. Parallel command queues can exceed 100%. Missing driver counters appear as gaps."
        }
    }
    func value(_ point: HistoryPoint) -> Double? {
        switch self { case .cpu: return point.cpu; case .memory: return point.memory; case .gpu: return point.gpu }
    }
    func peak(_ values: MetricValues) -> Double? {
        switch self { case .cpu: return values.cpu; case .memory: return values.memory; case .gpu: return values.gpu }
    }
    func chartValue(_ value: Double) -> Double { self == .memory ? value / 1_073_741_824 : value }
    func formatted(_ value: Double?) -> String {
        guard let value else { return "—" }
        if self == .memory {
            return value >= 1_073_741_824 ? String(format: "%.2f GB", value / 1_073_741_824) : String(format: "%.0f MB", value / 1_048_576)
        }
        return String(format: "%.1f%%", value)
    }
}

struct ChartPoint: Identifiable {
    let timestamp: Date
    let value: Double
    let segment: Int
    var id: Date { timestamp }
}

struct MetricChart: View {
    let kind: MetricKind
    let history: HistoryReply?
    let range: HistoryRange
    let running: Bool
    @State private var hovered: Date?

    private var points: [ChartPoint] {
        guard let history else { return [] }
        var segment = 0
        var previous: Double?
        var previousRun: String?
        return history.points.compactMap { point in
            guard let value = kind.value(point) else { segment += 1; previous = nil; return nil }
            if let previous, point.timestamp - previous > max(60, history.resolution) * 2.5 { segment += 1 }
            if let previousRun, previousRun != point.run { segment += 1 }
            previous = point.timestamp
            previousRun = point.run
            return ChartPoint(timestamp: point.date, value: kind.chartValue(value), segment: segment)
        }
    }
    private var selected: HistoryPoint? {
        hovered.flatMap { history?.sample(near: $0) }
    }
    private func inspect(_ location: CGPoint, proxy: ChartProxy, plot: CGRect) {
        hovered = plot.contains(location) ? proxy.value(atX: location.x - plot.minX, as: Date.self) : nil
    }
    private var domain: ClosedRange<Date> {
        let end = history.map { Date(timeIntervalSince1970: $0.end) } ?? Date()
        return end.addingTimeInterval(-range.duration)...end
    }
    private var upper: Double {
        let maximum = points.map(\.value).max() ?? 0
        return kind == .memory ? max(0.125, maximum * 1.15) : max(100, ceil(maximum / 100) * 100)
    }
    var body: some View {
        let samples = points
        let segmentCounts = Dictionary(grouping: samples, by: \.segment).mapValues(\.count)
        return VStack(spacing: 5) {
            ZStack {
                HStack(spacing: 5) {
                    Image(systemName: kind.icon).font(.system(size: 11)).foregroundStyle(kind.color)
                    Text(kind.rawValue).font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text((running ? "Now " : "Last ") + kind.formatted(history?.latest.flatMap { kind.value($0) }))
                        .foregroundStyle(kind.color)
                    if let history, let peak = kind.peak(history.peaks) {
                        Text("Peak " + kind.formatted(peak)).foregroundStyle(.secondary)
                    }
                }.font(.system(size: 9)).monospacedDigit()
                if hovered != nil {
                    Text(selected.flatMap { kind.value($0) }.map { kind.formatted($0) } ?? "No sample")
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(kind.color)
                        .accessibilityLabel("Selected " + kind.rawValue)
                }
            }.frame(height: 16).help(kind.help)
            Chart {
                ForEach(samples) { point in
                    LineMark(x: .value("Time", point.timestamp), y: .value(kind.rawValue, point.value),
                             series: .value("Interval", point.segment))
                        .foregroundStyle(kind.color).lineStyle(StrokeStyle(lineWidth: 1.7))
                    if segmentCounts[point.segment] == 1 {
                        PointMark(x: .value("Time", point.timestamp), y: .value(kind.rawValue, point.value))
                            .foregroundStyle(kind.color).symbolSize(14)
                    }
                }
                if let hovered {
                    RuleMark(x: .value("Selected time", selected?.date ?? hovered)).foregroundStyle(Color.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    if let selected, let value = kind.value(selected) {
                        PointMark(x: .value("Selected time", selected.date), y: .value(kind.rawValue, kind.chartValue(value)))
                            .foregroundStyle(kind.color).symbolSize(28)
                    }
                }
            }
            .chartXScale(domain: domain).chartYScale(domain: 0...upper)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date, format: range.duration >= 86400 ? .dateTime.month(.abbreviated).day().hour() : .dateTime.hour().minute())
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(kind == .memory ? (upper < 1 ? String(format: "%.0fM", number * 1024) : String(format: "%.1fG", number)) : String(format: "%.0f%%", number))
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                inspect(location, proxy: proxy, plot: geometry[proxy.plotAreaFrame])
                            case .ended: hovered = nil
                            }
                        }
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            inspect(value.location, proxy: proxy, plot: geometry[proxy.plotAreaFrame])
                        })
                }
            }
            .overlay(alignment: .bottom) {
                if let hovered {
                    Text(selected?.date ?? hovered, format: range.duration >= 86400
                         ? .dateTime.month(.abbreviated).day().hour().minute().second()
                         : .dateTime.hour().minute().second())
                        .font(.system(size: 9)).monospacedDigit().padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.regularMaterial, in: Capsule()).allowsHitTesting(false)
                }
            }
            .overlay {
                if samples.isEmpty {
                    Text(history?.points.isEmpty == false ? "Waiting for a measurement…" : running ? "History starts as samples arrive" : "No recorded history")
                        .font(.system(size: 10)).foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
            .frame(height: 64)
            .accessibilityLabel(kind.rawValue + " history. " + kind.formatted((hovered == nil ? history?.latest : selected).flatMap { kind.value($0) }))
            .onDisappear { hovered = nil }
        }.padding(9).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PerformanceView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var performance: PerformanceMonitor
    let identifier: String
    private var family: String { monitor.family(identifier) }
    private var title: String { family == "bridge" ? "AI Bridge" : family == "image" ? "Image Generator" : "Voice Generator" }
    private var running: Bool { monitor.statuses.first(where: { $0.id == identifier })?.running ?? performance.history?.running ?? false }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button { monitor.performanceID = nil } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .medium))
                        .frame(width: 36, height: 32).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Back to services")
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(running ? "Performance · includes child processes" : "Stopped · showing recorded history").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if performance.loading { ProgressView().controlSize(.mini) }
                Button { performance.sample(); performance.loadHistory() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11)).frame(width: 20, height: 24)
                }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Refresh performance")
            }
            Divider()
            if family != "bridge" {
                Picker("Process", selection: Binding(get: { identifier }, set: { monitor.showPerformance($0) })) {
                    Text("Service").tag(family)
                    Text("Queue").tag(family + "-queue")
                }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
            }
            Picker("Time range", selection: $performance.range) {
                ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().controlSize(.small).accessibilityLabel("Time range")
            VStack(spacing: 8) {
                ForEach(MetricKind.allCases, id: \.self) { kind in
                    MetricChart(kind: kind, history: performance.history, range: performance.range, running: running)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                if let error = performance.error {
                    Text(error).foregroundStyle(.red).lineLimit(2)
                } else {
                    HStack {
                        Text("CPU: 100% = 1 core")
                        Spacer()
                        Text("15s live · 1m background")
                    }
                    if let history = performance.history, let since = history.recording_since {
                        HStack {
                            Text("Recording since \(Date(timeIntervalSince1970: since), format: .dateTime.month(.abbreviated).day().hour().minute())")
                            Spacer()
                            if history.resolution > 15 { Text("\(Int(history.resolution / 60))m averages") }
                        }
                    } else { Text("History is saved locally for 7 days") }
                }
            }.font(.system(size: 9)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(12)
    }
}
