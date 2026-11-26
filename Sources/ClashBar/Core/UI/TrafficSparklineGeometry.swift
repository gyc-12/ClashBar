import CoreGraphics

/// Monotone cubic interpolation keeps traffic peaks within the measured range.
struct TrafficSparklineGeometry {
    static let pointLimit = 60

    struct Segment {
        let start: CGPoint
        let control1: CGPoint
        let control2: CGPoint
        let end: CGPoint
    }

    let axisY: CGFloat
    let up: [CGPoint]
    let down: [CGPoint]

    init(upValues: [Int64], downValues: [Int64], size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 4 else {
            self.axisY = 0
            self.up = []
            self.down = []
            return
        }
        self.axisY = size.height / 2
        let span = max(0, self.axisY - 2)
        let upload = Array(upValues.suffix(Self.pointLimit))
        let download = Array(downValues.suffix(Self.pointLimit))
        let maximum = max(1, Double(max(upload.max() ?? 0, download.max() ?? 0)))
        let axis = self.axisY

        func points(_ values: [Int64], direction: CGFloat) -> [CGPoint] {
            values.enumerated().map { index, value in
                let offset = values.count - 1 - index
                let x = size.width * (1 - CGFloat(offset) / CGFloat(Self.pointLimit - 1))
                let ratio = CGFloat(max(0, Double(value)) / maximum)
                return CGPoint(x: x, y: axis + direction * span * ratio)
            }
        }
        self.up = points(upload, direction: -1)
        self.down = points(download, direction: 1)
    }

    static func segments(_ points: [CGPoint]) -> [Segment] {
        guard points.count > 1 else { return [] }
        let slopes = zip(points, points.dropFirst()).map { start, end in
            (end.y - start.y) / (end.x - start.x)
        }
        var tangents = [slopes[0]]
        for index in 1..<points.count - 1 {
            let before = slopes[index - 1]
            let after = slopes[index]
            tangents.append(before * after > 0 ? 2 * before * after / (before + after) : 0)
        }
        tangents.append(slopes[slopes.count - 1])

        for index in slopes.indices {
            let slope = slopes[index]
            if slope == 0 {
                tangents[index] = 0
                tangents[index + 1] = 0
            } else {
                let sum = tangents[index] / slope + tangents[index + 1] / slope
                if sum > 3 {
                    let scale = 3 / sum
                    tangents[index] *= scale
                    tangents[index + 1] *= scale
                }
            }
        }
        return slopes.indices.map { index in
            let start = points[index]
            let end = points[index + 1]
            let third = (end.x - start.x) / 3
            return Segment(start: start,
                           control1: CGPoint(x: start.x + third, y: start.y + tangents[index] * third),
                           control2: CGPoint(x: end.x - third, y: end.y - tangents[index + 1] * third),
                           end: end)
        }
    }
}
