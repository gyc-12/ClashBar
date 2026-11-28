import Darwin
import Foundation

struct MihomoDNSAnswer: Decodable, Equatable, Sendable {
    let name: String?
    let type: Int?
    let ttl: Int?
    let data: String?

    private enum CodingKeys: String, CodingKey {
        case name, type, ttl = "TTL", data
    }
}

struct MihomoDNSQueryResponse: Decodable, Equatable, Sendable {
    let status: Int?
    let answers: [MihomoDNSAnswer]?

    private enum CodingKeys: String, CodingKey {
        case status = "Status", answers = "Answer"
    }
}

enum LocalIPv6Status: Equatable, Sendable {
    case available(address: String, isULA: Bool)
    case unavailable
}

enum LocalIPv6Inspector {
    static func detect() -> LocalIPv6Status {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return .unavailable }
        defer { freeifaddrs(addresses) }

        var ulaCandidate: String?
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0, (flags & IFF_LOOPBACK) == 0,
                  let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var sin6 = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            let bytes = withUnsafeBytes(of: &sin6.sin6_addr) { Array($0) }
            guard bytes.count == 16 else { continue }
            // Skip link-local (fe80::/10) and multicast (ff00::/8).
            if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 { continue }
            if bytes[0] == 0xFF { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &sin6.sin6_addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { continue }
            let text = String(decoding: buffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
            let isGlobal = (bytes[0] & 0xE0) == 0x20
            let isULA = (bytes[0] & 0xFE) == 0xFC
            if isGlobal {
                return .available(address: text, isULA: false)
            }
            if isULA, ulaCandidate == nil {
                ulaCandidate = text
            }
        }
        if let ulaCandidate {
            return .available(address: ulaCandidate, isULA: true)
        }
        return .unavailable
    }
}

struct EgressIPInfo: Decodable, Equatable, Sendable {
    let ip: String
    let country: String?
    let region: String?
    let city: String?
    let org: String?

    var summary: String {
        let parts = [ip, country?.trimmedNonEmpty, org?.trimmedNonEmpty].compactMap { $0 }
        return parts.joined(separator: " · ")
    }
}

enum EgressCheckResult: Equatable, Sendable {
    case resolved(ipv4: EgressIPInfo?, ipv6: String?)
    case proxyUnavailable
    case proxyAuthRequired
    case controllerError
    case failed
}

struct ClaudeRegionEvaluation: Sendable {
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
        let lower = page.html.lowercased()
        let denial = #"(?i)(?:app\s+unavailable|claude\s+is\s+(?:currently\s+)?(?:not\s+available|unavailable)\s+in\s+your\s+(?:country|region)|anthropic.{0,40}not\s+available\s+in\s+your\s+(?:country|region))"#
        if page.html.range(of: denial, options: .regularExpression) != nil { return .regionRestricted(loc) }
        if let loc, Self.blockedRegions.contains(loc) { return .regionRestricted(loc) }
        let challenges = ["just a moment", "verify you are human", "cf-mitigated", "attention required", "enable javascript and cookies"]
        if page.status == 403 || page.status == 451 {
            return challenges.contains(where: lower.contains) ? .indeterminate : .regionRestricted(loc)
        }
        guard page.url.scheme == "https",
              let host = page.url.host?.lowercased(), host == "claude.ai" || host.hasSuffix(".claude.ai"),
              page.status == 200 else { return .indeterminate }
        guard !challenges.contains(where: lower.contains), let loc else { return .indeterminate }
        return .regionSupported(loc)
    }
}

enum NetworkDiagnosticsProbe {
    static let ipInfoURL = "https://ipinfo.io/json"
    static let ipv4FallbackURL = "https://api.ipify.org?format=json"
    static let ipv6URL = "https://api6.ipify.org?format=json"
    static let claudeURL = "https://claude.ai/"
    static let claudeTraceURL = "https://claude.ai/cdn-cgi/trace"

    static func checkClaude(client: any MihomoAPITransporting, host: String?,
                            fetch: @Sendable (URL, String) async throws -> GeminiPage = GeminiRegionProbe.fetchPage) async -> SiteCheckResult {
        let config: ConfigSnapshot
        do { config = try await client.request(.getConfigs) } catch { return .controllerError }
        guard let proxy = GeminiRegionProbe.proxyURL(host: host, config: config) else { return .proxyUnavailable }
        do {
            let trace = try? await fetch(proxy, claudeTraceURL)
            try Task.checkCancellation()
            let page = try await fetch(proxy, claudeURL)
            return ClaudeRegionEvaluation(trace: trace, page: page).regionResult
        }
        catch URLError.timedOut { return .timeout }
        catch URLError.cannotConnectToHost { return .proxyUnavailable }
        catch URLError.userAuthenticationRequired { return .proxyAuthRequired }
        catch URLError.cannotParseResponse { return .indeterminate }
        catch { return .unreachable }
    }

    static func checkEgress(client: any MihomoAPITransporting, host: String?,
                            fetch: @Sendable (URL, String) async throws -> GeminiPage = GeminiRegionProbe.fetchPage) async -> EgressCheckResult {
        let config: ConfigSnapshot
        do { config = try await client.request(.getConfigs) } catch { return .controllerError }
        guard let proxy = GeminiRegionProbe.proxyURL(host: host, config: config) else { return .proxyUnavailable }

        var ipv4: EgressIPInfo?
        do {
            let page = try await fetch(proxy, ipInfoURL)
            if page.status == 200, let decoded = decodeEgressInfo(from: page.html) {
                ipv4 = decoded
            }
        } catch URLError.userAuthenticationRequired {
            return .proxyAuthRequired
        } catch URLError.cannotConnectToHost {
            return .proxyUnavailable
        } catch {
            // Fall through to api.ipify.org
        }

        if ipv4 == nil {
            do {
                let fallback = try await fetch(proxy, ipv4FallbackURL)
                if fallback.status == 200, let decoded = decodeEgressInfo(from: fallback.html) {
                    ipv4 = decoded
                }
            } catch URLError.userAuthenticationRequired {
                return .proxyAuthRequired
            } catch URLError.cannotConnectToHost {
                return .proxyUnavailable
            } catch {}
        }

        var ipv6: String?
        if let v6Page = try? await fetch(proxy, ipv6URL),
           v6Page.status == 200,
           let decoded = decodeEgressInfo(from: v6Page.html),
           decoded.ip.contains(":") {
            ipv6 = decoded.ip
        }

        guard ipv4 != nil || ipv6 != nil else { return .failed }
        return .resolved(ipv4: ipv4, ipv6: ipv6)
    }

    static func decodeEgressInfo(from body: String) -> EgressIPInfo? {
        guard let data = body.data(using: .utf8),
              let info = try? JSONDecoder().decode(EgressIPInfo.self, from: data),
              !info.ip.trimmed.isEmpty else { return nil }
        return info
    }

    static func normalizeDomain(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let host = URLComponents(string: candidate)?.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty, host.contains("."), !host.contains(" ") else { return nil }
        return host
    }

    static func isFakeIP(_ address: String) -> Bool {
        address.hasPrefix("198.18.") || address.hasPrefix("198.19.")
    }
}

struct DomainDiagnosticResult: Equatable, Sendable {
    let domain: String
    let aRecords: [String]
    let aaaaRecords: [String]
    let dnsFailed: Bool
    let reachability: SiteCheckResult

    var hasFakeIP: Bool {
        aRecords.contains(where: NetworkDiagnosticsProbe.isFakeIP)
    }
}

enum DomainDiagnosticProbe {
    static func diagnose(domain rawDomain: String, group: String?, client: any MihomoAPITransporting) async -> DomainDiagnosticResult? {
        guard let domain = NetworkDiagnosticsProbe.normalizeDomain(rawDomain) else { return nil }

        async let aQuery: Result<MihomoDNSQueryResponse, Error> = {
            do { return .success(try await client.request(.dnsQuery(name: domain, type: "A"))) }
            catch { return .failure(error) }
        }()
        async let aaaaQuery: Result<MihomoDNSQueryResponse, Error> = {
            do { return .success(try await client.request(.dnsQuery(name: domain, type: "AAAA"))) }
            catch { return .failure(error) }
        }()
        async let delayCheck: SiteCheckResult = {
            guard let group else { return .controllerError }
            do {
                let response: DelayMeasurement = try await client.request(
                    .proxyDelay(name: group, url: "https://\(domain)/", timeout: 8000, expected: "200-399"))
                guard let delay = response.value, delay > 0 else { return .unreachable }
                return .reachable(delay)
            } catch APIError.statusCode(504, _) { return .timeout }
            catch APIError.statusCode(503, _) { return .unreachable }
            catch { return .controllerError }
        }()

        let (aResult, aaaaResult, reachability) = await (aQuery, aaaaQuery, delayCheck)
        let aRecords: [String] = switch aResult {
        case let .success(resp):
            (resp.answers ?? []).compactMap { answer in
                guard answer.type == 1, let ip = answer.data?.trimmedNonEmpty else { return nil }
                return ip
            }
        case .failure: []
        }
        let aaaaRecords: [String] = switch aaaaResult {
        case let .success(resp):
            (resp.answers ?? []).compactMap { answer in
                guard answer.type == 28, let ip = answer.data?.trimmedNonEmpty else { return nil }
                return ip
            }
        case .failure: []
        }
        let dnsFailed: Bool
        if case .failure = aResult, case .failure = aaaaResult {
            dnsFailed = true
        } else {
            dnsFailed = false
        }

        return DomainDiagnosticResult(
            domain: domain,
            aRecords: aRecords,
            aaaaRecords: aaaaRecords,
            dnsFailed: dnsFailed,
            reachability: reachability)
    }
}
