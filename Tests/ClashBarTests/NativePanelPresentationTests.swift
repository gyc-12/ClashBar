import AppKit
import Foundation
import SwiftUI
import Testing

@testable import ClashBar

struct NativePanelPresentationTests {
    @Test func trafficInterpolationNeverInventsPeaksOrNegativeTraffic() {
        let fixtures: [[Int64]] = [
            [0, 0, 0, 0], [0, 1_000_000, 0, 1, 0], [1, 2, 3, 4], [4, 3, 2, 1],
            [0, Int64.max, 0, Int64.max, 0], [-10, 0, 500, 500, -1],
        ]
        for values in fixtures {
            let geometry = TrafficSparklineGeometry(upValues: values, downValues: values, size: CGSize(width: 320, height: 58))
            for points in [geometry.up, geometry.down] {
                for segment in TrafficSparklineGeometry.segments(points) {
                    let minimum = min(segment.start.y, segment.end.y) - 0.00001
                    let maximum = max(segment.start.y, segment.end.y) + 0.00001
                    for index in 0...100 {
                        let t = CGFloat(index) / 100
                        let u = 1 - t
                        let y = u * u * u * segment.start.y + 3 * u * u * t * segment.control1.y
                            + 3 * u * t * t * segment.control2.y + t * t * t * segment.end.y
                        #expect(y.isFinite && y >= minimum && y <= maximum)
                        #expect(y >= 2 - 0.00001 && y <= 56 + 0.00001)
                    }
                    #expect(segment.control1.x > segment.start.x && segment.control2.x < segment.end.x)
                }
            }
        }
    }

    @Test func trafficHistoryUsesOnlyRecentSamplesAndStaysAlignedToNow() {
        let recent = [Int64](repeating: 100, count: 60)
        let geometry = TrafficSparklineGeometry(upValues: [Int64.max] + recent, downValues: [], size: CGSize(width: 320, height: 58))
        #expect(geometry.up.count == 60)
        #expect(geometry.up.first?.x == 0 && geometry.up.last?.x == 320)
        #expect(geometry.up.allSatisfy { abs($0.y - 2) < 0.00001 })
        let partial = TrafficSparklineGeometry(upValues: [0, 10], downValues: [5], size: CGSize(width: 320, height: 58))
        #expect(partial.up.first?.x ?? 0 > 300)
        #expect(partial.up.last?.x == partial.down.last?.x)
    }

    @Test func trafficHandlesEmptySingleAndInvalidSizes() {
        let empty = TrafficSparklineGeometry(upValues: [], downValues: [], size: CGSize(width: 320, height: 58))
        #expect(empty.up.isEmpty && empty.down.isEmpty)
        let single = TrafficSparklineGeometry(upValues: [0], downValues: [0], size: CGSize(width: 320, height: 58))
        #expect(single.up == [CGPoint(x: 320, y: 29)])
        #expect(single.down == single.up)
        #expect(TrafficSparklineGeometry.segments(single.up).isEmpty)
        for size in [CGSize.zero, CGSize(width: -1, height: 58), CGSize(width: 320, height: 3)] {
            let invalid = TrafficSparklineGeometry(upValues: [1, 2], downValues: [1, 2], size: size)
            #expect(invalid.up.isEmpty && invalid.down.isEmpty)
        }
    }

    @Test func latencyKeepsFailureUnknownAndThresholdsDistinct() {
        #expect(LatencyTier(nil) == .unknown)
        #expect(LatencyTier(0) == .failed && LatencyTier(-1) == .failed)
        #expect(LatencyTier(1) == .fast && LatencyTier(149) == .fast)
        #expect(LatencyTier(150) == .moderate && LatencyTier(350) == .moderate)
        #expect(LatencyTier(351) == .slow)
    }

    @Test func localizationKeysAndFormattingArgumentsMatch() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("Sources/ClashBar/Resources/Localization")
        var tables: [[String: String]] = []
        let keys = try NSRegularExpression(pattern: #"(?m)^"([^"]+)"\s*="#)
        let arguments = try NSRegularExpression(pattern: #"(?<!%)%(?:\d+\$)?[-+0-9.]*(?:ll|l|z)?[@diuoxXfFeEgGcCsS]"#)
        for language in AppLanguage.allCases {
            let data = try Data(contentsOf: directory.appendingPathComponent("\(language.rawValue).lproj/Localizable.strings"))
            let table = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            let source = String(decoding: data, as: UTF8.self)
            #expect(keys.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source)) == table.count)
            tables.append(table)
        }
        #expect(Set(tables[0].keys) == Set(tables[1].keys))
        for key in tables[0].keys {
            let signatures = tables.map { table in
                let value = table[key] ?? ""
                return arguments.matches(in: value, range: NSRange(value.startIndex..., in: value))
                    .map { (value as NSString).substring(with: $0.range) }.sorted()
            }
            #expect(signatures[0] == signatures[1], "Formatting arguments differ for \(key)")
        }
    }

    @MainActor
    @Test func attachedMenuFitsRequestedOuterBoundsIncludingPadding() {
        let host = NSHostingView(rootView: AttachedPopoverSurface(width: 320, maxHeight: 180) {
            VStack {
                ForEach(0..<12) { index in
                    Text("A long proxy node name \(index)").frame(height: 40)
                }
            }
        })
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        #expect(abs(host.fittingSize.width - 320) < 0.5)
        #expect(host.fittingSize.height <= 180 && host.fittingSize.height > 0)
    }

    @MainActor
    @Test func expandedPanelFitsShortScreensAndScreenEdges() {
        let context = PanelAnchorContext(visibleFrame: CGRect(x: 0, y: 0, width: 1024, height: 320),
                                         anchorFrameOnScreen: CGRect(x: 1000, y: 320, width: 24, height: 24), hostWindowFrame: nil)
        let maximum = context.maximumHeightBelowMenuBar(screenPadding: 6, verticalSpacing: 3)
        let layout = PopoverLayoutModel(maxPanelHeight: maximum, preferredPanelHeight: 900)
        let placement = context.menuBarDropdownPlacement(panelSize: CGSize(width: MenuBarLayoutTokens.panelWidth, height: layout.resolvedPanelHeight),
            options: MenuBarDropdownPlacementOptions(horizontalPadding: 6, verticalSpacing: 3, screenPadding: 6,
                                                     lockedOriginX: nil, preserveHorizontalPosition: false))
        #expect(context.visibleFrame.contains(placement.frame))
        #expect(placement.frame.width == 376 && layout.resolvedPanelHeight <= maximum)
        layout.updateMaximumPanelHeight(240)
        #expect(layout.resolvedPanelHeight == 240)
    }
}
