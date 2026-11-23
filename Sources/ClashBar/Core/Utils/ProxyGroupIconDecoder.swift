import AppKit
import Foundation
import ImageIO

/// Converts unsupported-by-ImageIO SVG into the same raster cache format as other icons.
enum ProxyGroupIconDecoder {
    static let maximumBytes = 2 * 1024 * 1024
    static let pixelSize = 64

    static func normalizedData(_ data: Data) async -> Data? {
        guard !data.isEmpty, data.count <= self.maximumBytes else { return nil }
        if self.isRasterImage(data) { return data }
        guard let svg = self.selfContainedSVG(data) else { return nil }
        return await self.renderSVG(svg)
    }

    static func isRasterImage(_ data: Data) -> Bool {
        guard !data.isEmpty,
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0
        else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    private static func selfContainedSVG(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8),
            !text.localizedCaseInsensitiveContains("<!ENTITY"),
            !text.localizedCaseInsensitiveContains("<?xml-stylesheet"),
            let document = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
            let root = document.rootElement(), root.localName == "svg",
            self.isSelfContained(root)
        else { return nil }
        // Serialize only the root: the AppKit decoder never receives a DOCTYPE or external DTD.
        return root.xmlString.data(using: .utf8)
    }

    private static func isSelfContained(_ element: XMLElement) -> Bool {
        let name = element.localName?.lowercased() ?? ""
        guard
            !["script", "foreignobject", "animate", "animatemotion", "animatetransform", "set", "discard"].contains(
                name
            )
        else { return false }
        for attribute in element.attributes ?? [] {
            let name = attribute.localName?.lowercased() ?? ""
            let value = attribute.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if name.hasPrefix("on") { return false }
            if ["href", "src", "base"].contains(name), !value.isEmpty, !value.hasPrefix("#") { return false }
            if !self.hasOnlyLocalCSSReferences(value) { return false }
        }
        if name == "style", !self.hasOnlyLocalCSSReferences(element.stringValue ?? "") { return false }
        return (element.children ?? []).allSatisfy { child in
            guard let child = child as? XMLElement else { return true }
            return self.isSelfContained(child)
        }
    }

    private static func hasOnlyLocalCSSReferences(_ text: String) -> Bool {
        // Escaped tokens and imports are unnecessary for these static icons and can hide URLs.
        guard !text.contains("\\"), !text.localizedCaseInsensitiveContains("@import") else { return false }
        let expression = /(?i)url\s*\(([^)]*)\)/
        return text.matches(of: expression).allSatisfy { match in
            let reference = match.1.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return reference.hasPrefix("#")
        }
    }

    @MainActor
    private static func renderSVG(_ data: Data) -> Data? {
        guard let image = NSImage(data: data),
            image.size.width.isFinite, image.size.height.isFinite,
            image.size.width > 0, image.size.height > 0,
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: self.pixelSize,
                pixelsHigh: self.pixelSize,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )?.retagging(with: .sRGB),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }
        let side = CGFloat(self.pixelSize)
        let scale = side / max(image.size.width, image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(
            x: (side - size.width) / 2,
            y: (side - size.height) / 2,
            width: size.width,
            height: size.height
        )
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.clear(CGRect(x: 0, y: 0, width: side, height: side))
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        guard let png = bitmap.representation(using: .png, properties: [:]), self.isRasterImage(png)
        else { return nil }
        return png
    }
}
