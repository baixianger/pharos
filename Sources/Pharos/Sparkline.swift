import SwiftUI

/// Tiny area sparkline (neutral system colour by default), modeled on Wick's SparklineView.
struct Sparkline: View {
    let values: [Int]
    var tint: Color = .secondary

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let maxV = CGFloat(max(values.max() ?? 1, 1))
            let n = max(values.count, 1)
            let stepX = n > 1 ? w / CGFloat(n - 1) : w
            let pts: [CGPoint] = values.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) * stepX, y: h - (CGFloat(v) / maxV) * h)
            }
            ZStack {
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: CGPoint(x: first.x, y: h))
                    for pt in pts { p.addLine(to: pt) }
                    p.addLine(to: CGPoint(x: pts.last?.x ?? 0, y: h))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    for pt in pts.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
