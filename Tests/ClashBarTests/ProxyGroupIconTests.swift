import AppKit
import CryptoKit
import Foundation
import ImageIO
import Testing

@testable import ClashBar

private let sampleSVG = Data(
    """
    <?xml version="1.0"?>
    <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
    <svg xmlns="http://www.w3.org/2000/svg" width="32" height="16" viewBox="0 0 32 16">
      <rect width="32" height="16" fill="#ff0000"/>
    </svg>
    """.utf8
)

@MainActor
struct ProxyGroupIconDecoderTests {
    @Test func rasterizesSVGWithColorTransparencyAndAspectRatio() async throws {
        #expect(!ProxyGroupIconDecoder.isRasterImage(sampleSVG))
        let png = try #require(await ProxyGroupIconDecoder.normalizedData(sampleSVG))
        let bitmap = try #require(NSBitmapImageRep(data: png))
        #expect(bitmap.pixelsWide == 64)
        #expect(bitmap.pixelsHigh == 64)
        // Check encoded channels directly: colorAt returns a calibrated NSColor, even for an sRGB bitmap.
        var middle = [UInt](repeating: 0, count: 4)
        bitmap.getPixel(&middle, atX: 32, y: 32)
        #expect(middle[0] > 230)
        #expect(middle[1] < 25)
        #expect(middle[3] > 230)
        #expect(try #require(bitmap.colorAt(x: 32, y: 0)).alphaComponent < 0.01)
        #expect(try #require(bitmap.colorAt(x: 32, y: 63)).alphaComponent < 0.01)
        // Existing PNG takes the lossless fast path; it is not re-encoded.
        #expect(await ProxyGroupIconDecoder.normalizedData(png) == png)
    }

    @Test func rendersLocalGradientReferences() async throws {
        let svg = Data(
            """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
              <defs><linearGradient id="color"><stop offset="0" stop-color="red"/><stop offset="1" stop-color="blue"/></linearGradient></defs>
              <rect width="64" height="64" fill="url(#color)"/>
            </svg>
            """.utf8
        )
        let png = try #require(await ProxyGroupIconDecoder.normalizedData(svg))
        let bitmap = try #require(NSBitmapImageRep(data: png))
        var left = [UInt](repeating: 0, count: 4)
        var right = left
        bitmap.getPixel(&left, atX: 5, y: 32)
        bitmap.getPixel(&right, atX: 58, y: 32)
        #expect(left[0] > left[2])
        #expect(right[2] > right[0])
        #expect(left[3] > 230 && right[3] > 230)
    }

    @Test(arguments: [
        "", "not an image", "<html><body>Forbidden</body></html>", "<svg><path",
        "<svg xmlns='http://www.w3.org/2000/svg'><script>alert(1)</script></svg>",
        "<svg xmlns='http://www.w3.org/2000/svg'><image href='https://example.com/a.png'/></svg>",
        "<svg xmlns='http://www.w3.org/2000/svg'><image href='file:///etc/hosts'/></svg>",
        "<svg xmlns='http://www.w3.org/2000/svg' onload='alert(1)'/>",
        "<svg xmlns='http://www.w3.org/2000/svg'><style>@import 'https://example.com/a.css';</style></svg>",
        "<svg xmlns='http://www.w3.org/2000/svg'><rect fill='url(https://example.com/a.svg)'/></svg>",
        "<!DOCTYPE svg [<!ENTITY x 'data'>]><svg xmlns='http://www.w3.org/2000/svg'>&x;</svg>",
        "<svg xmlns='http://www.w3.org/2000/svg'><foreignObject><p>text</p></foreignObject></svg>",
        "<svg xmlns='http://www.w3.org/2000/svg'><image><set attributeName='href' to='https://example.com/a.png'/></image></svg>",
    ])
    func rejectsNonImagesAndExternalContent(text: String) async {
        #expect(await ProxyGroupIconDecoder.normalizedData(Data(text.utf8)) == nil)
    }

    @Test func rejectsOversizeData() async {
        let data = sampleSVG + Data(repeating: 32, count: ProxyGroupIconDecoder.maximumBytes)
        #expect(await ProxyGroupIconDecoder.normalizedData(data) == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLASHBAR_TEST_ICON_DIR"] != nil))
    func realConfigurationIconsRenderAndProduceContactSheet() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CLASHBAR_TEST_ICON_DIR"]))
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "svg" || $0.pathExtension == "png" }.sorted {
                $0.lastPathComponent < $1.lastPathComponent
            }
        #expect(!files.isEmpty)
        var icons: [(String, NSImage)] = []
        for file in files {
            let data = try Data(contentsOf: file)
            let normalized = try #require(
                await ProxyGroupIconDecoder.normalizedData(data),
                "Cannot decode \(file.lastPathComponent)"
            )
            let image = try #require(NSImage(data: normalized))
            let bitmap = try #require(NSBitmapImageRep(data: normalized))
            #expect(
                (0..<bitmap.pixelsHigh).contains { y in
                    (0..<bitmap.pixelsWide).contains { x in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 }
                },
                "Blank icon \(file.lastPathComponent)"
            )
            icons.append((file.deletingPathExtension().lastPathComponent, image))
        }
        let columns = 6
        let width = columns * 120
        let height = ((icons.count + columns - 1) / columns) * 100
        let sheet = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for (index, item) in icons.enumerated() {
            let x = (index % columns) * 120
            let y = height - (index / columns + 1) * 100
            item.1.draw(in: NSRect(x: x + 28, y: y + 27, width: 64, height: 64))
            (item.0 as NSString).draw(
                at: NSPoint(x: x + 10, y: y + 7),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black,
                ]
            )
        }
        let output = folder.appendingPathComponent("rendered", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try #require(sheet.representation(using: .png, properties: [:])).write(
            to: output.appendingPathComponent("icons.png")
        )
    }
}

private final class IconProtocolResponses: @unchecked Sendable {
    struct Response {
        let status: Int
        let data: Data
        let contentLength: Int
    }
    private let lock = NSLock()
    private var responses: [URL: Response] = [:]
    private var counts: [URL: Int] = [:]

    func set(_ response: Response, for url: URL) { self.lock.withLock { self.responses[url] = response } }
    func take(_ url: URL) -> Response? {
        self.lock.withLock {
            self.counts[url, default: 0] += 1
            return self.responses[url]
        }
    }
    func count(_ url: URL) -> Int { self.lock.withLock { self.counts[url, default: 0] } }
}

private final class IconURLProtocol: URLProtocol, @unchecked Sendable {
    static let responses = IconProtocolResponses()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = self.request.url, let stub = Self.responses.take(url),
            let response = HTTPURLResponse(
                url: url,
                statusCode: stub.status,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": String(stub.contentLength), "Content-Type": "application/octet-stream",
                ]
            )
        else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: stub.data)
        self.client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct ProxyGroupIconCacheTests {
    private func fixture() throws -> (URL, URLSession, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clashbar-icons-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IconURLProtocol.self]
        let url = try #require(URL(string: "https://icons.example/\(UUID()).svg"))
        return (folder, URLSession(configuration: config), url)
    }

    @Test func downloadsOnceAndReusesMemoryAndDisk() async throws {
        let (folder, session, url) = try self.fixture()
        defer {
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: folder)
        }
        IconURLProtocol.responses.set(.init(status: 200, data: sampleSVG, contentLength: sampleSVG.count), for: url)
        let cache = ProxyGroupIconCache(iconDirectory: folder, session: session)
        async let first = cache.imageData(for: url)
        async let second = cache.imageData(for: url)
        let (a, b) = await (first, second)
        let png = try #require(a)
        #expect(ProxyGroupIconDecoder.isRasterImage(png))
        #expect(b == png)
        #expect(IconURLProtocol.responses.count(url) == 1)
        #expect(await cache.imageData(for: url) == png)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        #expect(try Data(contentsOf: #require(files.first)) == png)
        IconURLProtocol.responses.set(.init(status: 503, data: Data(), contentLength: 0), for: url)
        let reopened = ProxyGroupIconCache(iconDirectory: folder, session: session)
        #expect(await reopened.imageData(for: url) == png)
        #expect(IconURLProtocol.responses.count(url) == 1)
    }

    @Test func invalidResponseAndCorruptCacheCanRecover() async throws {
        let (folder, session, url) = try self.fixture()
        defer {
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: folder)
        }
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        try Data("broken".utf8).write(to: folder.appendingPathComponent(hash))
        let cache = ProxyGroupIconCache(iconDirectory: folder, session: session)
        for (status, data, length) in [
            (404, sampleSVG, sampleSVG.count),
            (200, Data("<html>error</html>".utf8), 18),
            (200, sampleSVG, ProxyGroupIconDecoder.maximumBytes + 1),
            (200, Data(repeating: 32, count: ProxyGroupIconDecoder.maximumBytes + 1), -1),
        ] {
            IconURLProtocol.responses.set(.init(status: status, data: data, contentLength: length), for: url)
            #expect(await cache.imageData(for: url) == nil)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        }
        IconURLProtocol.responses.set(.init(status: 200, data: sampleSVG, contentLength: sampleSVG.count), for: url)
        #expect(await cache.imageData(for: url) != nil)
        #expect(IconURLProtocol.responses.count(url) == 5)
    }

    @Test func pngDownloadRemainsUnchanged() async throws {
        let (folder, session, url) = try self.fixture()
        defer {
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: folder)
        }
        let png = try #require(await ProxyGroupIconDecoder.normalizedData(sampleSVG))
        IconURLProtocol.responses.set(.init(status: 200, data: png, contentLength: png.count), for: url)
        let cache = ProxyGroupIconCache(iconDirectory: folder, session: session)
        #expect(await cache.imageData(for: url) == png)
    }
}
