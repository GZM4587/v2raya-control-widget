import SwiftUI

/// 迷你流量曲线：下行绿色、上行蓝色，按最近采样自适应缩放。
struct TrafficChart: View {
    let points: [TrafficPoint]
    var height: CGFloat = 64

    private var maxValue: Double {
        let m = points.flatMap { [Double($0.up), Double($0.down)] }.max() ?? 0
        return max(m, 1) // avoid divide-by-zero; keep a floor of 1 B/s
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if points.count < 2 {
                    Text("等待流量数据…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                } else {
                    ChartArea(values: points.map { Double($0.down) }, maxValue: maxValue)
                        .fill(Color.green.opacity(0.18))
                    ChartLine(values: points.map { Double($0.down) }, maxValue: maxValue)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    ChartLine(values: points.map { Double($0.up) }, maxValue: maxValue)
                        .stroke(Color(red: 0.25, green: 0.55, blue: 1.0),
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(height: height)
    }
}

/// 折线路径（等间距采样）
private struct ChartLine: Shape {
    let values: [Double]
    let maxValue: Double

    func path(in rect: CGRect) -> Path {
        guard values.count > 1, maxValue > 0 else { return Path() }
        let pts = points(in: rect)
        var p = Path()
        p.move(to: pts[0])
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        return p
    }

    private func points(in rect: CGRect) -> [CGPoint] {
        let step = rect.width / CGFloat(max(values.count - 1, 1))
        return values.enumerated().map { idx, v in
            let ratio = min(max(v / maxValue, 0), 1)
            return CGPoint(x: rect.minX + step * CGFloat(idx),
                           y: rect.maxY - rect.height * CGFloat(ratio))
        }
    }
}

/// 面积路径（下行曲线下方填充）
private struct ChartArea: Shape {
    let values: [Double]
    let maxValue: Double

    func path(in rect: CGRect) -> Path {
        guard values.count > 1, maxValue > 0 else { return Path() }
        let step = rect.width / CGFloat(max(values.count - 1, 1))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for (idx, v) in values.enumerated() {
            let ratio = min(max(v / maxValue, 0), 1)
            p.addLine(to: CGPoint(x: rect.minX + step * CGFloat(idx),
                                  y: rect.maxY - rect.height * CGFloat(ratio)))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
