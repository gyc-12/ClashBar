import Foundation

struct GeminiPage: Sendable {
    let url: URL
    let status: Int
    let contentType: String
    let html: String

    var regionResult: SiteCheckResult {
        let mediaType = contentType.lowercased().components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces)
        guard url.scheme == "https", url.host?.lowercased() == "gemini.google.com",
              mediaType == "text/html",
              status == 200 || status == 403 else { return .indeterminate }
        let text = html.replacingOccurrences(of: #"(?is)<!--.*?-->|<(script|style|template)\b[^>]*>.*?</\1\s*>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)&(?:apos|rsquo|#39|#x27|#8217);|’"#, with: "'", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let bootstrap = html.replacingOccurrences(of: #"\""#, with: "\"")
        let regionPattern = #/,\s*2\s*,\s*1\s*,\s*200\s*,\s*"([A-Z]{3})"/#
        let regions = Set(bootstrap.matches(of: regionPattern).map { String($0.output.1) })
        let region = regions.count == 1 ? regions.first : nil
        let denial = #"(?i)Gemini\s*(?:(?:currently\s+)?is(?:n't| (?:currently )?not)\s+(?:(?:currently|yet)\s+)?(?:supported|available)\s+in\s+your\s+(?:country|region|location)|(?:目前|暂时?|暫時?|尚|当前|當前)?\s*(?:不支持|不支援|不適用於|不适用于)\s*(?:你|您)(?:所在)?的?(?:国家|國家|地区|地區))"#
        if text.range(of: denial, options: .regularExpression) != nil { return .regionRestricted(region) }
        let allowedPath = ["", "/", "/app", "/app/"].contains(url.path)
            || url.path.range(of: #"^/u/\d+/app/?$"#, options: .regularExpression) != nil
        guard allowedPath else { return .indeterminate }
        let interstitials = ["unusual traffic", "verify you are human", "before you continue to Google", "Sign in - Google Accounts", "Sign in – Google Accounts"]
        guard status == 200, let region, !["ZZZ", "XXX", "UNK"].contains(region),
              !interstitials.contains(where: text.localizedCaseInsensitiveContains) else { return .indeterminate }
        if ["CHN", "RUS", "BLR", "CUB", "IRN", "PRK", "SYR", "HKG", "MAC"].contains(region) { return .regionRestricted(region) }
        let positiveFlag = #"(?:\b45631641\s*,\s*null\s*,\s*true\b|"45631641"\s*:\s*true\b)"#
        let negativeFlag = #"(?:\b45631641\s*,\s*null\s*,\s*false\b|"45631641"\s*:\s*false\b)"#
        guard bootstrap.range(of: denial, options: .regularExpression) == nil,
              bootstrap.range(of: positiveFlag, options: .regularExpression) != nil,
              bootstrap.range(of: negativeFlag, options: .regularExpression) == nil else { return .indeterminate }
        return .regionSupported(region)
    }
}

struct ChatGPTRegionEvaluation: Sendable {
    let trace: GeminiPage?
    let page: GeminiPage

    static let blockedRegions: Set<String> = ["CN", "HK", "MO", "RU", "BY", "IR", "KP", "SY", "CU"]

    var traceLocation: String? {
        guard let trace, trace.status == 200 else { return nil }
        for line in trace.html.components(separatedBy: .newlines) where line.hasPrefix("loc=") {
            let code = String(line.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if code.count == 2, code.allSatisfy(\.isASCII), code.allSatisfy(\.isLetter), code != "XX" {
                return code
            }
        }
        return nil
    }

    var regionResult: SiteCheckResult {
        let loc = traceLocation
        let mediaType = page.contentType.lowercased().components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces)
        let lower = page.html.lowercased()
        let denial = #"(?i)(?:unsupported_country|openai(?:'s|’s)?\s+services\s+are\s+not\s+available\s+in\s+your\s+country|chatgpt\s+is\s+(?:currently\s+)?not\s+available\s+in\s+your\s+(?:country|region))"#
        if page.html.range(of: denial, options: .regularExpression) != nil { return .regionRestricted(loc) }
        if let loc, Self.blockedRegions.contains(loc) { return .regionRestricted(loc) }
        let challenges = ["just a moment", "verify you are human", "cf-mitigated", "attention required", "enable javascript and cookies"]
        if page.status == 403 || page.status == 451 {
            return challenges.contains(where: lower.contains) ? .indeterminate : .regionRestricted(loc)
        }
        guard page.url.scheme == "https",
              let host = page.url.host?.lowercased(), host == "chatgpt.com" || host.hasSuffix(".chatgpt.com"),
              page.status == 200, mediaType == "text/html" else { return .indeterminate }
        guard !challenges.contains(where: lower.contains), lower.contains("chatgpt"), let loc else { return .indeterminate }
        return .regionSupported(loc)
    }
}

enum GeminiRegionProbe {
    static let url = "https://gemini.google.com/app"
    private static let homepage = "https://gemini.google.com/"
    static let chatGPTURL = "https://chatgpt.com/"
    static let chatGPTTraceURL = "https://chatgpt.com/cdn-cgi/trace"
    private static let byteLimit = 8 * 1024 * 1024

    static func check(client: any MihomoAPITransporting, host: String?,
                      fetch: @Sendable (URL, String) async throws -> GeminiPage = fetchPage) async -> SiteCheckResult {
        let config: ConfigSnapshot
        do { config = try await client.request(.getConfigs) } catch { return .controllerError }
        guard let proxy = proxyURL(host: host, config: config) else { return .proxyUnavailable }
        do {
            let entry = try await fetch(proxy, url)
            let result = entry.regionResult
            guard result == .indeterminate, entry.url.host?.lowercased() == "accounts.google.com" else { return result }
            try Task.checkCancellation()
            if let publicPage = try? await fetch(proxy, homepage), case let .regionRestricted(code) = publicPage.regionResult {
                return .regionRestricted(code)
            }
            return .indeterminate
        }
        catch URLError.timedOut { return .timeout }
        catch URLError.cannotConnectToHost { return .proxyUnavailable }
        catch URLError.userAuthenticationRequired { return .proxyAuthRequired }
        catch URLError.cannotParseResponse { return .indeterminate }
        catch { return .unreachable }
    }

    static func checkChatGPT(client: any MihomoAPITransporting, host: String?,
                             fetch: @Sendable (URL, String) async throws -> GeminiPage = fetchPage) async -> SiteCheckResult {
        let config: ConfigSnapshot
        do { config = try await client.request(.getConfigs) } catch { return .controllerError }
        guard let proxy = proxyURL(host: host, config: config) else { return .proxyUnavailable }
        do {
            let trace = try? await fetch(proxy, chatGPTTraceURL)
            try Task.checkCancellation()
            let page = try await fetch(proxy, chatGPTURL)
            return ChatGPTRegionEvaluation(trace: trace, page: page).regionResult
        }
        catch URLError.timedOut { return .timeout }
        catch URLError.cannotConnectToHost { return .proxyUnavailable }
        catch URLError.userAuthenticationRequired { return .proxyAuthRequired }
        catch URLError.cannotParseResponse { return .indeterminate }
        catch { return .unreachable }
    }

    static func proxyURL(host: String?, config: ConfigSnapshot) -> URL? {
        guard let rawHost = host?.trimmingCharacters(in: .whitespacesAndNewlines), !rawHost.isEmpty else { return nil }
        let normalizedHost: String = switch rawHost {
        case "0.0.0.0": "127.0.0.1"
        case "::", "[::]": "::1"
        default: rawHost
        }
        let candidates = [("http", config.mixedPort), ("http", config.port), ("socks5h", config.socksPort)]
        for (scheme, port) in candidates {
            guard let port, (1...65535).contains(port) else { continue }
            var components = URLComponents()
            components.scheme = scheme
            components.host = normalizedHost.contains(":") && !normalizedHost.hasPrefix("[") ? "[\(normalizedHost)]" : normalizedHost
            components.port = port
            return components.url
        }
        return nil
    }

    static func fetchPage(proxy: URL, target: String) async throws -> GeminiPage {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--disable", "--silent", "--proxy", proxy.absoluteString, "--noproxy", "", "--globoff",
            "--proto", "=https", "--proto-redir", "=https", "--location", "--max-redirs", "8", "--connect-timeout", "5", "--max-time", "15",
            "--max-filesize", String(byteLimit), "--header", "Accept-Language: en-US,en;q=0.9", "--header", "Accept: text/html,text/plain",
            "--user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            "--write-out", "\n%{response_code}\n%{content_type}\n%{url_effective}\n%{http_connect}", target]
        process.environment = ["LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        try process.run()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                defer { try? output.fileHandleForReading.close() }
                var bytes = Data()
                while let chunk = try output.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                    guard bytes.count + chunk.count <= byteLimit + 8192 else {
                        if process.isRunning { process.terminate() }
                        throw URLError(.cannotParseResponse)
                    }
                    bytes.append(chunk)
                }
                process.waitUntilExit()
                let fields = (0..<4).compactMap { _ -> String? in
                    guard let separator = bytes.lastIndex(of: 10) else { return nil }
                    let field = String(decoding: bytes.suffix(from: separator + 1), as: UTF8.self)
                    bytes.removeSubrange(separator...)
                    return field
                }
                if fields.first == "407" { throw URLError(.userAuthenticationRequired) }
                switch process.terminationStatus {
                case 0: break
                case 5, 7: throw URLError(.cannotConnectToHost)
                case 28: throw URLError(.timedOut)
                case 47, 63: throw URLError(.cannotParseResponse)
                default: throw URLError(.networkConnectionLost)
                }
                guard fields.count == 4, let finalURL = URL(string: fields[1]), let status = Int(fields[3]), bytes.count <= byteLimit else {
                    throw URLError(.cannotParseResponse)
                }
                return GeminiPage(url: finalURL, status: status, contentType: fields[2], html: String(decoding: bytes, as: UTF8.self))
            }.value
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
