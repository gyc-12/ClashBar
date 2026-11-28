import Darwin
import Foundation
import Testing

@testable import ClashBar

struct GeminiRegionTests {
    private let legacyPositive = #"<script>var data=[45631641,null,true,2,1,200,"USA"];</script>"#
    private let jsonPositive = #"<script>window.WIZ_global_data={"45631641":true,"x":[4,2,1,200,"USA"]};</script>"#

    private func page(_ html: String, status: Int = 200, url: String = GeminiRegionProbe.url, type: String = "text/html; charset=utf-8") -> GeminiPage {
        GeminiPage(url: URL(string: url)!, status: status, contentType: type, html: html)
    }

    @Test func readableRegionalRefusalsOverrideHttpSuccessAndPositiveMarkers() {
        for message in ["Gemini 目前不支持你所在的地区。敬请期待！", "Gemini目前不支持您所在的地区。",
                        "Gemini isn&#39;t currently supported in your country. Stay tuned!", "Gemini is not available in your region."] {
            #expect(page("<p>\(message)</p>").regionResult == .regionRestricted(nil))
            #expect(page(legacyPositive + "<h1>\(message)</h1>").regionResult == .regionRestricted("USA"))
            #expect(page(jsonPositive + "<h1>\(message)</h1>").regionResult == .regionRestricted("USA"))
        }
        #expect(page(#"<script>[4,2,1,200,\"HKG\"]</script>"#).regionResult == .regionRestricted("HKG"))
        #expect(page("Gemini isn't supported in your country", status: 403).regionResult == .regionRestricted(nil))
        #expect(page("<p>Gemini isn't supported in your country</p>", url: "https://gemini.google.com/unavailable").regionResult == .regionRestricted(nil))
    }

    @Test func onlyRecognizedGeminiHtmlWithPositiveSignalsCanPass() {
        #expect(page(legacyPositive).regionResult == .regionSupported("USA"))
        #expect(page(jsonPositive).regionResult == .regionSupported("USA"))
        #expect(page(jsonPositive, url: "https://gemini.google.com/u/0/app").regionResult == .regionSupported("USA"))
        for html in ["Sign in to Google", "Welcome to Gemini", #"[null,2,1,200,"USA"]"#, "45631641,null,true",
                     legacyPositive.replacingOccurrences(of: "true", with: "false"), legacyPositive + "[45631641,null,false]",
                     jsonPositive.replacingOccurrences(of: "true", with: "false"), jsonPositive + #"{"45631641":false}"#,
                     legacyPositive + #"[9,2,1,200,"CAN"]"#, legacyPositive + "Verify you are human", legacyPositive + "Sign in - Google Accounts",
                     legacyPositive.replacingOccurrences(of: "USA", with: "ZZZ"), legacyPositive + "<script>var msg='Gemini 目前不支持你所在的地区。'</script>"] {
            #expect(page(html).regionResult == .indeterminate)
        }
        for url in ["https://accounts.google.com/", "https://consent.google.com/", "https://gemini.google.com/sorry/", "http://gemini.google.com/"] {
            #expect(page(legacyPositive, url: url).regionResult == .indeterminate)
        }
        for status in [302, 401, 403, 429, 500] { #expect(page(legacyPositive, status: status).regionResult == .indeterminate) }
        #expect(page(legacyPositive, type: "application/json").regionResult == .indeterminate)
        #expect(page("<script>const translation='Gemini 目前不支持你所在的地区。'</script>").regionResult == .indeterminate)
    }

    @Test func chatGPTRegionCheckDistinguishesSupportedBlockedAndChallenges() {
        let usTrace = page("fl=1\nh=chatgpt.com\nloc=US\n", url: GeminiRegionProbe.chatGPTTraceURL, type: "text/plain")
        let hkTrace = page("fl=1\nh=chatgpt.com\nloc=HK\n", url: GeminiRegionProbe.chatGPTTraceURL, type: "text/plain")
        let okPage = page("<html class=\"chatgpt-theme\"><title>ChatGPT</title></html>", url: GeminiRegionProbe.chatGPTURL)
        let challengePage = page("<html><title>Just a moment...</title></html>", status: 403, url: GeminiRegionProbe.chatGPTURL)
        let blockedPage = page("<html>OpenAI's services are not available in your country.</html>", status: 403, url: GeminiRegionProbe.chatGPTURL)

        #expect(ChatGPTRegionEvaluation(trace: usTrace, page: okPage).regionResult == .regionSupported("US"))
        #expect(ChatGPTRegionEvaluation(trace: hkTrace, page: okPage).regionResult == .regionRestricted("HK"))
        #expect(ChatGPTRegionEvaluation(trace: usTrace, page: blockedPage).regionResult == .regionRestricted("US"))
        #expect(ChatGPTRegionEvaluation(trace: usTrace, page: challengePage).regionResult == .indeterminate)
        #expect(ChatGPTRegionEvaluation(trace: nil, page: okPage).regionResult == .indeterminate)
    }

    private struct Controller: MihomoAPITransporting {
        let config: String
        func request<Value: Decodable>(_ endpoint: Endpoint) async throws -> Value {
            guard case .getConfigs = endpoint else { Issue.record("Region check must not use the delay API"); throw APIError.invalidURL }
            return try JSONDecoder().decode(Value.self, from: Data(config.utf8))
        }
        func requestNoResponse(_ endpoint: Endpoint) async throws { Issue.record("A check must not change the route") }
    }

    @Test func checksCurrentCorePortAndNeverFallsBackToADelayOrLocalDirect() async {
        for (config, host, endpoint) in [(#"{"mixed-port":8000,"port":8001}"#, "remote.example", "http://remote.example:8000"),
                                        (#"{"port":8001}"#, "::1", "http://[::1]:8001"),
                                        (#"{"port":8001}"#, "0.0.0.0", "http://127.0.0.1:8001"),
                                        (#"{"port":8001}"#, "::", "http://[::1]:8001"),
                                        (#"{"mixed-port":0,"socks-port":8002}"#, "127.0.0.1", "socks5h://127.0.0.1:8002")] {
            let result = await GeminiRegionProbe.check(client: Controller(config: config), host: host) { proxy, target in
                #expect(proxy.absoluteString == endpoint)
                #expect(target == "https://gemini.google.com/app")
                return page("Gemini 目前不支持你所在的地区。敬请期待！")
            }
            #expect(result == .regionRestricted(nil))
        }
        #expect(await ReachabilitySite.gemini.check(group: "us", client: Controller(config: #"{"port":0,"socks-port":99999}"#), proxyHost: "remote.example") == .proxyUnavailable)
        #expect(await ReachabilitySite.chatGPTRegion.check(group: "us", client: Controller(config: #"{"port":0}"#), proxyHost: "remote.example") == .proxyUnavailable)
        #expect(await ReachabilitySite.gemini.check(group: "us", client: Controller(config: "invalid"), proxyHost: nil) == .controllerError)
        let result = await GeminiRegionProbe.check(client: Controller(config: #"{"port":8001}"#), host: "localhost") { _, _ in throw URLError(.timedOut) }
        #expect(result == .timeout)
    }

    @Test func loginRedirectCannotBeUpgradedToSuccessByTheMarketingHomepage() async {
        for (body, expected) in [(jsonPositive, SiteCheckResult.indeterminate), ("Gemini 目前不支持你所在的地区。敬请期待！", .regionRestricted(nil))] {
            let result = await GeminiRegionProbe.check(client: Controller(config: #"{"port":8000}"#), host: "localhost") { _, target in
                if target == GeminiRegionProbe.url { return page("Sign in", url: "https://accounts.google.com/signin") }
                #expect(target == "https://gemini.google.com/")
                return page(body, url: target)
            }
            #expect(result == expected)
        }
    }

    @Test func realFetcherUsesOnlyExplicitProxyAndReportsAuthentication() async throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        try #require(listener >= 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try #require(withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) } } == 0)
        try #require(listen(listener, 1) == 0)
        try #require(withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } } == 0)
        let port = UInt16(bigEndian: address.sin_port)
        let server = Task.detached { () -> String in
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 5000) > 0 else { return "" }
            let socket = accept(listener, nil, nil)
            guard socket >= 0 else { return "" }
            defer { close(socket) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = recv(socket, &buffer, buffer.count, 0)
            let response = Array("HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            _ = send(socket, response, response.count, 0)
            return String(decoding: buffer.prefix(max(0, count)), as: UTF8.self)
        }
        let result = await ReachabilitySite.gemini.check(group: "unused", client: Controller(config: "{\"port\":\(port)}"), proxyHost: "127.0.0.1")
        let request = await server.value
        #expect(request.hasPrefix("CONNECT gemini.google.com:443 HTTP/"))
        #expect(!request.lowercased().contains("authorization:"))
        #expect(result == .proxyAuthRequired)
    }
}
