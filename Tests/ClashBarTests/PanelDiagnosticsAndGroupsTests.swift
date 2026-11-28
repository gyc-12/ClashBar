import Foundation
import Testing

@testable import ClashBar

struct PanelDiagnosticsAndGroupsTests {
    private let dnsService = NativeDNSSettingsService()
    private let providerService = NativeProxyProviderService()
    private let configURL = URL(fileURLWithPath: "/unused/config.yaml")

    @Test func nativeDNSIPv6TogglesInPlaceWhileKeepingCommentsAndOtherKeys() throws {
        let yaml = """
            ipv6: false
            dns:
              enable: true
              ipv6: false # keep note
              enhanced-mode: fake-ip
              fake-ip-range: 198.18.0.1/16
            rules:
              - MATCH,DIRECT # clashbar:custom
            """
        let snapshot = try dnsService.read(configURL: configURL, data: Data(yaml.utf8))
        #expect(snapshot.dnsEnabled && !snapshot.dnsIPv6 && snapshot.enhancedMode == "fake-ip")

        let enabled = try dnsService.prepareDNSIPv6(true, snapshot: snapshot)
        let enabledText = String(decoding: enabled.updatedData, as: UTF8.self)
        #expect(enabledText.contains("  ipv6: true # keep note"))
        #expect(enabledText.contains("ipv6: false\ndns:"))
        #expect(enabledText.contains("# clashbar:custom"))
        #expect(try dnsService.read(configURL: configURL, data: enabled.updatedData).dnsIPv6)

        // When dns block omits ipv6 key, toggling true inserts it cleanly.
        let withoutKey = try dnsService.read(configURL: configURL, data: Data("dns:\n  enable: true\nrules: []\n".utf8))
        let inserted = try dnsService.prepareDNSIPv6(true, snapshot: withoutKey)
        #expect(try dnsService.read(configURL: configURL, data: inserted.updatedData).dnsIPv6)

        // When dns block is completely absent, toggling true appends dns.ipv6 cleanly.
        let noDNS = try dnsService.read(configURL: configURL, data: Data("mode: rule\nrules: []\n".utf8))
        let appended = try dnsService.prepareDNSIPv6(true, snapshot: noDNS)
        #expect(try dnsService.read(configURL: configURL, data: appended.updatedData).dnsIPv6)
    }

    @MainActor @Test func customHealthcheckURLValidatesPersistsAndFallsBack() throws {
        let env = try NativeRuleTestEnvironment()
        defer { env.clean() }
        let model = env.model
        #expect(model.defaultHealthcheckURL == AppViewModel.builtInHealthcheckURL)

        #expect(model.updateCustomHealthcheckURL(AppViewModel.cloudflareHealthcheckURL))
        #expect(model.defaultHealthcheckURL == AppViewModel.cloudflareHealthcheckURL)

        #expect(!model.updateCustomHealthcheckURL("ftp://invalid.example"))
        #expect(model.defaultHealthcheckURL == AppViewModel.cloudflareHealthcheckURL)

        #expect(model.updateCustomHealthcheckURL("   "))
        #expect(model.defaultHealthcheckURL == AppViewModel.builtInHealthcheckURL)
    }

    @Test func createsAndConfiguresGroupsWithProvidersAndRegexValidation() throws {
        let initial = try providerService.read(configURL: configURL, data: Data("""
            # top comment
            proxy-providers:
              SubA: {type: http, url: 'https://example.invalid/a', path: ./a.yaml}
              SubB: {type: http, url: 'https://example.invalid/b', path: ./b.yaml}
            proxy-groups:
              - name: PROXY
                type: select
                proxies: [DIRECT]
            rules:
              - MATCH,PROXY # clashbar:custom
            """.utf8))

        // Invalid regex is rejected before writing.
        #expect(throws: NativeProxyProviderError.invalidRegex) {
            try providerService.prepare(
                .configureGroup(
                    name: "AI-US",
                    draft: NativeGroupDraft(type: "url-test", members: [], use: ["SubA"], includeAllProviders: false, filter: "[unclosed"),
                    create: true),
                in: initial)
        }

        // Duplicate or reserved names are rejected.
        #expect(throws: NativeProxyProviderError.invalidName) {
            try providerService.prepare(
                .configureGroup(name: "PROXY", draft: NativeGroupDraft(type: "select", members: ["DIRECT"]), create: true),
                in: initial)
        }
        #expect(throws: NativeProxyProviderError.invalidName) {
            try providerService.prepare(
                .configureGroup(name: "SubA", draft: NativeGroupDraft(type: "select", members: ["DIRECT"]), create: true),
                in: initial)
        }

        // Create a filtered url-test group bound to SubA.
        let created = try providerService.prepare(
            .configureGroup(
                name: "AI-US",
                draft: NativeGroupDraft(
                    type: "url-test", members: [], use: ["SubA"], includeAllProviders: false,
                    filter: "(?i)US", excludeFilter: "官网", defaultTestURL: "https://cp.cloudflare.com/generate_204"),
                create: true),
            in: initial)
        let createdText = String(decoding: created.file.updatedData, as: UTF8.self)
        #expect(createdText.contains("# top comment") && createdText.contains("# clashbar:custom"))
        let createdGroup = try #require(created.document.groups.first(where: { $0.name == "AI-US" }))
        #expect(createdGroup.type == "url-test" && createdGroup.use == ["SubA"] && createdGroup.filter == "(?i)US" && createdGroup.excludeFilter == "官网")
        let expanded = try providerService.expandedConfig(created.file.updatedData)
        let rawCreated = try #require(expanded["proxy-groups"]?.array().last)
        #expect(rawCreated["url"]?.string == "https://cp.cloudflare.com/generate_204" && rawCreated["interval"]?.int == 300)

        // Edit the created group to switch to include-all-providers and select type.
        let updated = try providerService.prepare(
            .configureGroup(
                name: "AI-US",
                draft: NativeGroupDraft(type: "select", members: ["DIRECT"], use: [], includeAllProviders: true, filter: nil, excludeFilter: nil),
                create: false),
            in: created.document)
        let updatedGroup = try #require(updated.document.groups.first(where: { $0.name == "AI-US" }))
        #expect(updatedGroup.type == "select" && updatedGroup.includeAllProviders && updatedGroup.use.isEmpty && updatedGroup.members == ["DIRECT"] && updatedGroup.filter == nil)
    }

    @Test func claudeEgressAndDomainDiagnosticsClassifyResponsesAccurately() async {
        let usTrace = GeminiPage(url: URL(string: NetworkDiagnosticsProbe.claudeTraceURL)!, status: 200, contentType: "text/plain", html: "fl=1\nloc=US\n")
        let hkTrace = GeminiPage(url: URL(string: NetworkDiagnosticsProbe.claudeTraceURL)!, status: 200, contentType: "text/plain", html: "fl=1\nloc=HK\n")
        let okClaude = GeminiPage(url: URL(string: NetworkDiagnosticsProbe.claudeURL)!, status: 200, contentType: "text/html", html: "<html>Claude</html>")
        let challengeClaude = GeminiPage(url: URL(string: NetworkDiagnosticsProbe.claudeURL)!, status: 403, contentType: "text/html", html: "<html>Just a moment</html>")
        let blockedClaude = GeminiPage(url: URL(string: NetworkDiagnosticsProbe.claudeURL)!, status: 200, contentType: "text/html", html: "<html>App unavailable: Claude is not available in your country</html>")

        #expect(ClaudeRegionEvaluation(trace: usTrace, page: okClaude).regionResult == .regionSupported("US"))
        #expect(ClaudeRegionEvaluation(trace: hkTrace, page: okClaude).regionResult == .regionRestricted("HK"))
        #expect(ClaudeRegionEvaluation(trace: usTrace, page: challengeClaude).regionResult == .indeterminate)
        #expect(ClaudeRegionEvaluation(trace: usTrace, page: blockedClaude).regionResult == .regionRestricted("US"))

        #expect(NetworkDiagnosticsProbe.normalizeDomain("https://Gemini.Google.com/app?x=1") == "gemini.google.com")
        #expect(NetworkDiagnosticsProbe.normalizeDomain("ippure.com") == "ippure.com")
        #expect(NetworkDiagnosticsProbe.normalizeDomain("not a domain") == nil)
        #expect(NetworkDiagnosticsProbe.isFakeIP("198.18.0.12") && !NetworkDiagnosticsProbe.isFakeIP("1.1.1.1"))

        struct MockController: MihomoAPITransporting {
            func request<Value: Decodable>(_ endpoint: Endpoint) async throws -> Value {
                switch endpoint {
                case .getConfigs:
                    return try JSONDecoder().decode(Value.self, from: Data(#"{"mixed-port":7890}"#.utf8))
                case let .dnsQuery(name, type):
                    #expect(name == "gemini.google.com")
                    let json = type == "A"
                        ? #"{"Status":0,"Answer":[{"name":"gemini.google.com.","type":1,"TTL":60,"data":"198.18.0.5"}]}"#
                        : #"{"Status":0,"Answer":[]}"#
                    return try JSONDecoder().decode(Value.self, from: Data(json.utf8))
                case let .proxyDelay(group, url, _, expected):
                    #expect(group == "PROXY" && url == "https://gemini.google.com/" && expected == "200-399")
                    return try JSONDecoder().decode(Value.self, from: Data(#"{"delay":88}"#.utf8))
                default:
                    throw APIError.invalidURL
                }
            }
            func requestNoResponse(_ endpoint: Endpoint) async throws {}
        }

        let egress = await NetworkDiagnosticsProbe.checkEgress(client: MockController(), host: "127.0.0.1") { _, target in
            if target == NetworkDiagnosticsProbe.ipInfoURL {
                return GeminiPage(url: URL(string: target)!, status: 200, contentType: "application/json",
                                  html: #"{"ip":"97.118.191.112","country":"US","org":"AS209 CenturyLink"}"#)
            }
            return GeminiPage(url: URL(string: target)!, status: 200, contentType: "application/json",
                              html: #"{"ip":"2600:1900::1"}"#)
        }
        #expect(egress == .resolved(
            ipv4: EgressIPInfo(ip: "97.118.191.112", country: "US", region: nil, city: nil, org: "AS209 CenturyLink"),
            ipv6: "2600:1900::1"))

        let domain = await DomainDiagnosticProbe.diagnose(domain: "https://gemini.google.com/app", group: "PROXY", client: MockController())
        #expect(domain?.aRecords == ["198.18.0.5"])
        #expect(domain?.hasFakeIP == true)
        #expect(domain?.aaaaRecords.isEmpty == true)
        #expect(domain?.reachability == .reachable(88))
    }
}
