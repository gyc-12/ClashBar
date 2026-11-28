import Foundation
import Testing

@testable import ClashBar

struct ProxyPanelToolsTests {
    let service = NativeProxyProviderService()

    private func document(_ yaml: String) throws -> NativeProxyProviderDocument {
        try service.read(configURL: URL(fileURLWithPath: "/unused/test.yaml"), data: Data(yaml.utf8))
    }

    @Test func nestedGroupsKeepNativeSourcesAndProtectDependencies() throws {
        let initial = try document("""
            proxy-providers: {feed: {type: inline, payload: []}}
            proxy-groups:
              - {name: proxy, type: select, proxies: [DIRECT], use: [feed], filter: abc}
              - {name: us, type: select, proxies: [DIRECT]}
              - {name: other, type: select, proxies: [us]}
            sub-rules: {special: ['MATCH,us']}
            rules: ['DOMAIN,us,proxy'] # untouched
            """)
        let edit = try service.prepare(.group(name: "proxy", members: ["us", "DIRECT"]), in: initial)
        let parent = try #require(service.expandedConfig(edit.document.data)["proxy-groups"]?.array().first)
        #expect(parent["proxies"]?.array().compactMap(\.string) == ["us", "DIRECT"])
        #expect(parent["filter"]?.string == "abc")
        #expect(parent["use"]?.array().compactMap(\.string) == ["feed"])
        #expect(String(decoding: edit.document.data, as: UTF8.self).contains("# untouched"))
        #expect(throws: NativeProxyProviderError.groupCycle) { try service.prepare(.group(name: "us", members: ["proxy"]), in: edit.document) }
        #expect(throws: NativeProxyProviderError.groupReferences(["proxy-groups → proxy", "proxy-groups → other", "sub-rules.special[1]"])) {
            try service.prepare(.group(name: "us", members: nil), in: edit.document)
        }
        #expect(throws: NativeProxyProviderError.emptyGroups(["us"])) { try service.prepare(.group(name: "us", members: []), in: initial) }
        let unlinked = try service.prepare(.group(name: "proxy", members: []), in: edit.document)
        let unlinkedParent = try #require(service.expandedConfig(unlinked.document.data)["proxy-groups"]?.array().first)
        #expect(unlinkedParent["proxies"] == nil)
        #expect(unlinked.document.groups[0].use == ["feed"])
        #expect(try service.prepare(.group(name: "other", members: nil), in: unlinked.document).document.groups.map(\.name) == ["proxy", "us"])
    }

    @Test func subscriptionTemplateUsesGeneralDefaultsAndSupportsUserOverrides() throws {
        let initial = try document("proxy-groups: [{name: PROXY, type: select, proxies: [DIRECT]}]")
        let url = "https://example.invalid/feed?Token=A%2B"
        let action = NativeProxyProviderAction.add(name: "Primary", url: url, interval: nil, healthCheckURL: nil, groups: [])
        let edit = try service.prepare(action, in: initial)
        let provider = try #require(service.expandedConfig(edit.document.data)["proxy-providers"]?["Primary"])
        #expect(provider["type"]?.string == "http" && provider["url"]?.string == url)
        #expect(provider["interval"]?.int == 3600 && provider["proxy"]?.string == "DIRECT")
        #expect(provider["health-check"]?["enable"]?.bool == true && provider["health-check"]?["interval"]?.int == 300)
        #expect(provider["health-check"]?["url"]?.string == "https://cp.cloudflare.com")
        #expect(provider["override"] == nil)
        #expect(provider["header"]?["User-Agent"]?.array().compactMap(\.string) == SubscriptionOptions.defaultAgents)
        #expect(provider["path"]?.string?.hasPrefix("./proxies/") == true)
        let (retry, route) = try #require(action.retryRoute(in: initial))
        #expect(route == "PROXY" && retry.retryRoute(in: initial) == nil)
        let chineseMain = try document("proxy-groups: [{name: '🚀 手动切换', type: select, proxies: [DIRECT]}]")
        #expect(action.retryRoute(in: chineseMain)?.1 == "🚀 手动切换")
        #expect(action.retryRoute(in: try document("rules: []")) == nil)
        let custom = SubscriptionOptions(healthEnabled: false, healthInterval: 42, downloadProxy: "PROXY", userAgents: ["one", "two"], prefix: "HK-")
        let next = try service.prepare(.add(name: "custom", url: url, interval: 0, healthCheckURL: "https://site.invalid/", groups: [], options: custom), in: edit.document)
        let updated = try #require(service.expandedConfig(next.document.data)["proxy-providers"]?["custom"])
        #expect(updated["health-check"]?["enable"]?.bool == false && updated["health-check"]?["interval"]?.int == 42)
        #expect(updated["health-check"]?["url"]?.string == "https://site.invalid/" && updated["interval"]?.int == 0)
        #expect(updated["override"]?["additional-prefix"]?.string == "HK-" && updated["proxy"]?.string == "PROXY")
        #expect(updated["header"]?["User-Agent"]?.array().compactMap(\.string) == ["one", "two"])
        #expect(updated["path"] != provider["path"])
    }

    @Test func renamesAndEditsExistingSubscriptionsWhilePreservingReferencesAndComments() throws {
        let initial = try document("""
            # Keep header comment
            proxy-providers:
              OldSub:
                type: http
                url: 'https://example.invalid/old'
                path: ./proxies/old.yaml
                interval: 0
                header:
                  X-Test: ['keep']
                  User-Agent: ['old-agent']
                override:
                  udp: true
                  additional-prefix: 'OLD-'
              Backup:
                type: file
                path: ./proxies/backup.yaml
            proxy-groups:
              - name: PROXY
                type: select
                use: [OldSub, Backup]
            rules:
              - MATCH,PROXY # clashbar:custom
            """)
        let loaded = try #require(initial.entries.first(where: { $0.name == "OldSub" }))
        #expect(loaded.interval == 0 && loaded.options.prefix == "OLD-" && loaded.options.userAgents == ["old-agent"])

        #expect(throws: NativeProxyProviderError.invalidName) {
            try service.prepare(.edit(name: "OldSub", newName: "PROXY", url: "https://example.invalid/old"), in: initial)
        }
        #expect(throws: NativeProxyProviderError.invalidName) {
            try service.prepare(.edit(name: "OldSub", newName: "Backup", url: "https://example.invalid/old"), in: initial)
        }

        let newOptions = SubscriptionOptions(healthEnabled: true, healthInterval: 180, downloadProxy: "PROXY", userAgents: ["clash.meta"], prefix: "")
        let edited = try service.prepare(
            .edit(name: "OldSub", newName: "NewSub", url: "https://example.invalid/old", interval: 1800,
                  healthCheckURL: "https://cp.cloudflare.com", options: newOptions),
            in: initial)
        #expect(edited.changesRuntime && !edited.freshSource && edited.probeProvider == "NewSub")
        let yamlText = String(decoding: edited.file.updatedData, as: UTF8.self)
        #expect(yamlText.contains("# Keep header comment") && yamlText.contains("# clashbar:custom"))
        let config = try service.expandedConfig(edited.file.updatedData)
        #expect(config["proxy-providers"]?["OldSub"] == nil)
        let sub = try #require(config["proxy-providers"]?["NewSub"])
        #expect(sub["path"]?.string == "./proxies/old.yaml")
        #expect(sub["interval"]?.int == 1800 && sub["proxy"]?.string == "PROXY")
        #expect(sub["health-check"]?["enable"]?.bool == true && sub["health-check"]?["interval"]?.int == 180)
        #expect(sub["header"]?["X-Test"]?.array(of: String.self) == ["keep"])
        #expect(sub["header"]?["User-Agent"]?.array(of: String.self) == ["clash.meta"])
        #expect(sub["override"]?["udp"]?.bool == true && sub["override"]?["additional-prefix"] == nil)
        #expect(config["proxy-groups"]?.array().first?["use"]?.array(of: String.self) == ["NewSub", "Backup"])

        // Disable, rename while disabled, and re-enable: group reference should restore under the new name.
        let disabled = try service.prepare(.setEnabled(name: "NewSub", enabled: false), in: edited.document)
        let renamedDisabled = try service.prepare(.edit(name: "NewSub", newName: "RestoredSub", url: "https://example.invalid/old"), in: disabled.document)
        #expect(!renamedDisabled.changesRuntime && renamedDisabled.probeProvider == nil)
        let reenabled = try service.prepare(.setEnabled(name: "RestoredSub", enabled: true), in: renamedDisabled.document)
        let restoredConfig = try service.expandedConfig(reenabled.file.updatedData)
        #expect(restoredConfig["proxy-groups"]?.array().first?["use"]?.array(of: String.self) == ["RestoredSub", "Backup"])
    }

    @MainActor @Test func repeatedPollsDoNotFoldSelectedUnknownOrNestedNodes() throws {
        let environment = try NativeRuleTestEnvironment()
        defer { environment.clean() }
        let model = environment.model
        model.foldTimeoutNodes = true
        let samples = (1...3).map { ProxyLatencySample(delay: 0, time: Date(timeIntervalSince1970: Double($0))) }
        let parent = ProxyGroup(name: "proxy", now: "selected", all: ["us", "selected", "other", "unknown"])
        func poll(_ history: [ProxyLatencySample]) {
            let response = ProxyGroupsResponse(proxies: ["proxy": parent, "us": ProxyGroup(name: "us", now: "other", all: ["other"], latencyHistory: history),
                "other": ProxyGroup(name: "other", all: [], latencyHistory: history), "selected": ProxyGroup(name: "selected", all: [], latencyHistory: history)])
            model.applyProxyGroupsResponse(response, proxyProviders: [:])
        }
        for _ in 1...3 { poll([samples[0]]) }
        #expect(model.foldedNodes(in: parent).isEmpty)
        poll(samples)
        #expect(model.foldedNodes(in: parent) == ["other"])
        let sub = try #require(model.proxyGroups.first { $0.name == "us" })
        #expect(model.foldedNodes(in: sub).isEmpty)
        model.applyMeasuredNodeDelays(["other": 10], testURL: "https://example.invalid/")
        poll(samples)
        #expect(model.foldedNodes(in: parent).isEmpty)
        poll(samples + [ProxyLatencySample(delay: 1, time: Date())])
        #expect(model.foldedNodes(in: parent).isEmpty)
        #expect(!ProxyLatencySample.hasConsecutiveTimeouts(Array(repeating: samples[0], count: 3)))
    }

    @Test func checksOnlySelectedRouteAndDistinguishesFailures() async {
        struct Transport: MihomoAPITransporting {
            var status: Int
            let site: ReachabilitySite
            func request<Value: Decodable>(_ endpoint: Endpoint) async throws -> Value {
                guard case let .proxyDelay(name, url, timeout, expected) = endpoint,
                      name == "指定组", url == site.url, timeout > 0, expected == "200-399" else {
                    Issue.record("Unexpected endpoint"); throw APIError.invalidURL
                }
                guard status == 200 else { throw APIError.statusCode(status, "") }
                return try JSONDecoder().decode(Value.self, from: Data(#"{"delay":42}"#.utf8))
            }
            func requestNoResponse(_ endpoint: Endpoint) async throws { Issue.record("Unexpected mutation") }
        }
        for site in [ReachabilitySite.chatGPT, .youtube] {
            for (status, result) in [(200, SiteCheckResult.reachable(42)), (504, .timeout), (503, .unreachable), (401, .controllerError)] {
                #expect(await site.check(group: "指定组", client: Transport(status: status, site: site), proxyHost: nil) == result)
            }
        }
    }
}
