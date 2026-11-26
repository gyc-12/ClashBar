import SwiftUI

struct TrafficSparklineView: View {
    let upValues: [Int64]
    let downValues: [Int64]

    var body: some View {
        GeometryReader { geo in
            let geometry = TrafficSparklineGeometry(upValues: self.upValues, downValues: self.downValues, size: geo.size)
            ZStack {
                self.grid(size: geo.size)
                    .stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
                self.area(geometry.up, axis: geometry.axisY)
                    .fill(LinearGradient(colors: [self.nativeInfo.opacity(0.22), self.nativeInfo.opacity(0.015)],
                                         startPoint: .top, endPoint: .center))
                self.area(geometry.down, axis: geometry.axisY)
                    .fill(LinearGradient(colors: [self.nativePositive.opacity(0.22), self.nativePositive.opacity(0.015)],
                                         startPoint: .bottom, endPoint: .center))
                self.line(geometry.up)
                    .stroke(self.nativeInfo.opacity(0.90), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                self.line(geometry.down)
                    .stroke(self.nativePositive.opacity(0.90), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                if geometry.up.count == 1, let point = geometry.up.first {
                    Circle().fill(self.nativeInfo).frame(width: 3, height: 3).position(point)
                }
                if geometry.down.count == 1, let point = geometry.down.first {
                    Circle().fill(self.nativePositive).frame(width: 3, height: 3).position(point)
                }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    private func line(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for segment in TrafficSparklineGeometry.segments(points) {
            path.addCurve(to: segment.end, control1: segment.control1, control2: segment.control2)
        }
        return path
    }

    private func area(_ points: [CGPoint], axis: CGFloat) -> Path {
        var path = self.line(points)
        guard let first = points.first, let last = points.last else { return path }
        path.addLine(to: CGPoint(x: last.x, y: axis))
        path.addLine(to: CGPoint(x: first.x, y: axis))
        path.closeSubpath()
        return path
    }

    private func grid(size: CGSize) -> Path {
        var path = Path()
        for fraction: CGFloat in [0.25, 0.5, 0.75] {
            path.move(to: CGPoint(x: 0, y: size.height * fraction))
            path.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
        }
        return path
    }
}
