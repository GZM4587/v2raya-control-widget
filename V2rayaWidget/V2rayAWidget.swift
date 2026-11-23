import WidgetKit
import SwiftUI
import AppKit
import AppIntents

// MARK: - Timeline

struct V2rayAEntry: TimelineEntry {
    let date: Date
    let snapshot: V2rayAStore.Snapshot
}

struct V2rayAProvider: TimelineProvider {
    func placeholder(in context: Context) -> V2rayAEntry {
        let now = Date()
        var hist: [(date: Date, up: Int64, down: Int64)] = []
        for i in 0..<20 {
            hist.append((now.addingTimeInterval(TimeInterval(-i * 5)),
                         Int64((20 - i) * 50_000),
                         Int64((20 - i) * 300_000)))
        }
        return V2rayAEntry(date: now, snapshot: V2rayAStore.Snapshot(
            isRunning: true, version: "2.5.16",
            upSpeed: 1_048_576, downSpeed: 5_242_880,
            upTotal: 104_857_600, downTotal: 524_288_000,
            history: hist, lastUpdated: now
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (V2rayAEntry) -> Void) {
        completion(V2rayAEntry(date: .now, snapshot: V2rayAStore.readSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<V2rayAEntry>) -> Void) {
        Task {
            var snap = V2rayAStore.readSnapshot()
            let stale = snap.lastUpdated.map { Date().timeIntervalSince($0) > 10 } ?? true

            if stale {
                if let s = await TrafficSampler.sampleOnce() {
                    snap.upSpeed = s.up
                    snap.downSpeed = s.down
                    snap.upTotal = s.upTotal
                    snap.downTotal = s.downTotal
                    snap.isRunning = true
                    snap.lastUpdated = .now
                    let now = Date()
                    snap.history.append((now, s.up, s.down))
                    if snap.history.count > 30 { snap.history.removeFirst(snap.history.count - 30) }
                    V2rayAStore.writeSnapshot(snap)
                } else {
                    let st = await V2rayAAPI.status()
                    if st.serviceUp {
                        snap.isRunning = st.isRunning
                        snap.version = st.version
                        snap.lastUpdated = .now
                    }
                }
            }
            let entry = V2rayAEntry(date: .now, snapshot: snap)
            V2rayAStore.writeDebug([
                "source": "widget-timeline",
                "sampleCount": snap.history.count,
                "upTotal": snap.upTotal,
                "downTotal": snap.downTotal,
                "upSpeed": snap.upSpeed,
                "downSpeed": snap.downSpeed,
                "time": Date().formatted(date: .omitted, time: .standard),
            ])
            let next = Calendar.current.date(byAdding: .minute, value: 10, to: .now)!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

// MARK: - Widget

struct V2rayAWidget: Widget {
    let kind = "V2rayAWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: V2rayAProvider()) { entry in
            V2rayAWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("V2rayA 代理")
        .description("一键开/关代理，查看上下行速率与流量曲线。")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

@main
struct V2rayAWidgetBundle: WidgetBundle {
    var body: some Widget {
        V2rayAWidget()
    }
}

// MARK: - View

struct V2rayAWidgetView: View {
    let entry: V2rayAEntry

    private var dotColor: Color {
        guard let t = entry.snapshot.lastUpdated else { return .gray }
        if Date().timeIntervalSince(t) > 1800 { return .gray }
        return entry.snapshot.isRunning ? .green : .red
    }

    private var statusText: String {
        guard let t = entry.snapshot.lastUpdated else { return "未连接" }
        if Date().timeIntervalSince(t) > 1800 { return "服务离线" }
        return entry.snapshot.isRunning ? "运行中" : "已停止"
    }

    var body: some View {
        // 点击组件空白区域 = 系统默认行为：启动宿主菜单栏 App
        HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Circle().fill(dotColor).frame(width: 8, height: 8)
                        Text(statusText)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    Text("v\(entry.snapshot.version)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 2)

                    Button(intent: ToggleProxyIntent(desired: !entry.snapshot.isRunning)) {
                        Image(systemName: entry.snapshot.isRunning ? "stop.circle.fill" : "play.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(entry.snapshot.isRunning ? Color.red : Color.green)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: 88, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    TrafficSparkline(points: entry.snapshot.history)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack(spacing: 10) {
                        Label(fmt(entry.snapshot.downSpeed), systemImage: "arrow.down")
                            .foregroundStyle(.green)
                        Label(fmt(entry.snapshot.upSpeed), systemImage: "arrow.up")
                            .foregroundStyle(Color(red: 0.25, green: 0.55, blue: 1.0))
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    HStack(spacing: 10) {
                        Text("总 ↓\(fmtTotal(entry.snapshot.downTotal))")
                        Text("总 ↑\(fmtTotal(entry.snapshot.upTotal))")
                        Spacer()
                        if let t = entry.snapshot.lastUpdated {
                            Text(t.formatted(.dateTime.hour().minute().second()))
                        }
                    }
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(12)
    }

    private func fmt(_ bps: Int64) -> String {
        let units = ["B/s", "K", "M", "G"]
        var v = Double(max(0, bps)); var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        if i == 0 { return "\(Int(v)) B/s" }
        return String(format: "%.1f%@", v, units[i])
    }

    private func fmtTotal(_ bytes: Int64) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var v = Double(max(0, bytes)); var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        if i == 0 { return "\(Int(v))\(units[i])" }
        return String(format: "%.1f%@", v, units[i])
    }
}

// MARK: - Sparkline

/// 双曲线迷你图（下行绿、上行蓝）
struct TrafficSparkline: View {
    let points: [(date: Date, up: Int64, down: Int64)]

    private var maxValue: Double {
        let m = points.flatMap { [Double($0.up), Double($0.down)] }.max() ?? 0
        return max(m, 1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if points.count >= 2 {
                    SparkArea(values: points.map { Double($0.down) }, maxValue: maxValue)
                        .fill(Color.green.opacity(0.15))
                    SparkLine(values: points.map { Double($0.down) }, maxValue: maxValue)
                        .stroke(Color.green, lineWidth: 1.5)
                    SparkLine(values: points.map { Double($0.up) }, maxValue: maxValue)
                        .stroke(Color(red: 0.25, green: 0.55, blue: 1.0), lineWidth: 1.2)
                } else {
                    Text("暂无流量数据")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                }
            }
        }
    }
}

private struct SparkLine: Shape {
    let values: [Double]
    let maxValue: Double

    func path(in rect: CGRect) -> Path {
        guard values.count > 1, maxValue > 0 else { return Path() }
        let step = rect.width / CGFloat(values.count - 1)
        var p = Path()
        for (i, v) in values.enumerated() {
            let pt = CGPoint(x: rect.minX + step * CGFloat(i),
                             y: rect.maxY - rect.height * CGFloat(min(max(v / maxValue, 0), 1)))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }
}

private struct SparkArea: Shape {
    let values: [Double]
    let maxValue: Double

    func path(in rect: CGRect) -> Path {
        guard values.count > 1, maxValue > 0 else { return Path() }
        let line = SparkLine(values: values, maxValue: maxValue).path(in: rect)
        var p = line
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
