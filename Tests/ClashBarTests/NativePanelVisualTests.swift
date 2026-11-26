import AppKit
import Foundation
import SwiftUI
import Testing

@testable import ClashBar

@MainActor
struct NativePanelVisualTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLASHBAR_TEST_RENDER_DIR"] != nil))
    func renderNativePanelForVisualReview() throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CLASHBAR_TEST_RENDER_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for language in AppLanguage.allCases {
            for (appearance, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                let environment = try NativeRuleTestEnvironment(coreOverride: DiagnosticsTestCore())
                defer { environment.model.cancelPolling(); environment.clean() }
                try self.populate(environment)
                let model = environment.model
                model.uiLanguage = language
                let suffix = "\(language.rawValue)-\(appearance).png"

                for tab in RootTab.allCases {
                    model.activeMenuTab = tab
                    model.apiStatus = .healthy
                    let layout = PopoverLayoutModel(maxPanelHeight: 640, preferredPanelHeight: 640)
                    try self.render(MenuBarRootView(), model: model, size: CGSize(width: MenuBarLayoutTokens.panelWidth, height: 640),
                                    scheme: scheme, layout: layout, path: directory.appendingPathComponent("panel-\(tab.rawValue)-\(suffix)"))
                    #expect(layout.resolvedPanelHeight <= layout.maxPanelHeight)
                }
                for tab in [RootTab.proxy, .rules] {
                    model.activeMenuTab = tab
                    let layout = PopoverLayoutModel(maxPanelHeight: 640, preferredPanelHeight: 640)
                    try self.render(MenuBarRootView(), model: model, size: CGSize(width: MenuBarLayoutTokens.panelWidth, height: 640),
                                    scheme: scheme, layout: layout, scrollOffset: 280,
                                    path: directory.appendingPathComponent("scrolled-\(tab.rawValue)-\(suffix)"))
                    let short = PopoverLayoutModel(maxPanelHeight: 360, preferredPanelHeight: 360)
                    try self.render(MenuBarRootView(), model: model, size: CGSize(width: MenuBarLayoutTokens.panelWidth, height: 360),
                                    scheme: scheme, layout: short, path: directory.appendingPathComponent("short-\(tab.rawValue)-\(suffix)"))
                    #expect(short.resolvedPanelHeight <= 360)
                    let scrolledShort = PopoverLayoutModel(maxPanelHeight: 360, preferredPanelHeight: 360)
                    try self.render(MenuBarRootView(), model: model, size: CGSize(width: MenuBarLayoutTokens.panelWidth, height: 360),
                                    scheme: scheme, layout: scrolledShort, scrollOffset: 280,
                                    path: directory.appendingPathComponent("short-scrolled-\(tab.rawValue)-\(suffix)"))
                }
                model.activeMenuTab = .system
                let systemLayout = PopoverLayoutModel(maxPanelHeight: 640, preferredPanelHeight: 640)
                try self.render(MenuBarRootView(), model: model, size: CGSize(width: MenuBarLayoutTokens.panelWidth, height: 640),
                                scheme: scheme, layout: systemLayout, scrollOffset: 420,
                                path: directory.appendingPathComponent("scrolled-system-\(suffix)"))
                model.activeMenuTab = .proxy
                model.proxyStore.groupLatencyLoading.insert("OpenAI")
                let testingLayout = PopoverLayoutModel(maxPanelHeight: 640, preferredPanelHeight: 640)
                try self.render(MenuBarRootView(), model: model, size: CGSize(width: MenuBarLayoutTokens.panelWidth, height: 640),
                                scheme: scheme, layout: testingLayout, scrollOffset: 280,
                                path: directory.appendingPathComponent("testing-proxy-\(suffix)"))
                model.proxyStore.groupLatencyLoading.remove("OpenAI")
                let document = try #require(model.nativeRuleDocument)
                let quick = QuickRuleEditorContext(configURL: environment.config,
                    target: QuickRuleTarget(type: .domain, value: "api.example.com"), policies: document.policies,
                    originalConfig: document.originalData, providers: [], isSubscription: true, notice: nil)
                try self.render(QuickRuleEditorView(context: quick), model: model,
                                size: CGSize(width: MenuBarLayoutTokens.Sheet.width, height: MenuBarLayoutTokens.Sheet.height),
                                scheme: scheme, path: directory.appendingPathComponent("sheet-quick-rule-\(suffix)"))
                try self.render(NativeRuleEditorView(context: NativeRuleEditorContext(document: document, entry: document.entries[0], isSubscription: true)),
                                model: model, size: CGSize(width: MenuBarLayoutTokens.Sheet.width, height: MenuBarLayoutTokens.Sheet.tallHeight),
                                scheme: scheme, path: directory.appendingPathComponent("sheet-native-rule-\(suffix)"))
                let chrome = ApplicationRoutingCandidate(name: "Google Chrome", processName: "Google Chrome",
                    processPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", bundlePath: nil)
                let curl = ApplicationRoutingCandidate(name: "curl", processName: "curl", processPath: "/usr/bin/curl", bundlePath: nil)
                let appContext = ApplicationRuleEditorContext(document: document, selected: chrome, observed: [chrome, curl],
                                                              processMode: "off", fileProcessMode: "off", isSubscription: true)
                try self.render(ApplicationRuleEditorView(context: appContext, applications: [chrome, curl]), model: model,
                                size: CGSize(width: MenuBarLayoutTokens.Sheet.wideWidth, height: MenuBarLayoutTokens.Sheet.tallHeight),
                                scheme: scheme, path: directory.appendingPathComponent("sheet-application-\(suffix)"))
                let providerDocument = try #require(model.nativeProxyProviderDocument)
                for operation in [ProxyProviderEditorContext.Operation.add, .edit, .enable, .disable, .delete] {
                    let entry = operation == .add ? nil : providerDocument.entries.first { $0.enabled == (operation != .enable) }
                    let context = ProxyProviderEditorContext(document: providerDocument, operation: operation, entry: entry,
                                                             isSubscription: true, willReload: true)
                    try self.render(ProxyProviderEditorView(context: context), model: model,
                                    size: CGSize(width: MenuBarLayoutTokens.Sheet.width, height: operation == .add ? 460 : 440),
                                    scheme: scheme, path: directory.appendingPathComponent("sheet-provider-\(operation)-\(suffix)"))
                }
                try self.render(ProxyGroupDetailView(name: "OpenAI"), model: model,
                                size: CGSize(width: MenuBarLayoutTokens.Sheet.wideWidth, height: MenuBarLayoutTokens.Sheet.height),
                                scheme: scheme, path: directory.appendingPathComponent("sheet-group-\(suffix)"))
                try self.render(ConnectionDetailView(snapshot: try #require(model.connectionsStore.connections.first)), model: model,
                                size: CGSize(width: MenuBarLayoutTokens.Sheet.wideWidth, height: MenuBarLayoutTokens.Sheet.height),
                                scheme: scheme, path: directory.appendingPathComponent("sheet-connection-\(suffix)"))
                try self.render(ConnectionDetailView(snapshot: try #require(model.connectionsStore.connections.first)), model: model,
                                size: CGSize(width: MenuBarLayoutTokens.Sheet.wideWidth, height: MenuBarLayoutTokens.Sheet.height),
                                scheme: scheme, scrollOffset: 260,
                                path: directory.appendingPathComponent("scrolled-sheet-connection-\(suffix)"))
                try self.render(ProxyGroupDetailView(name: "OpenAI"), model: model,
                                size: CGSize(width: MenuBarLayoutTokens.Sheet.wideWidth, height: MenuBarLayoutTokens.Sheet.height),
                                scheme: scheme, scrollOffset: 260,
                                path: directory.appendingPathComponent("scrolled-sheet-group-\(suffix)"))
                try self.render(self.nodeMenu(language: language), model: model,
                                size: CGSize(width: 320, height: 350), scheme: scheme,
                                path: directory.appendingPathComponent("node-menu-\(suffix)"))
                model.defaults.set(true, forKey: "clashbar.proxy.group.show_latency_history")
                try self.render(self.nodeMenu(language: language), model: model,
                                size: CGSize(width: 320, height: 350), scheme: scheme,
                                path: directory.appendingPathComponent("node-menu-history-\(suffix)"))
                model.defaults.set(false, forKey: "clashbar.proxy.group.show_latency_history")
                try self.render(self.componentGallery(language: language), model: model,
                                size: CGSize(width: MenuBarLayoutTokens.panelWidth, height: 400), scheme: scheme,
                                path: directory.appendingPathComponent("components-\(suffix)"))
                let root = ProxyGroupsViewModel()
                model.proxyGroups = [ProxyGroup(name: "很长的策略组名称 / International streaming and work services", type: "Selector",
                                               now: "Hong Kong · Premium international route with a long node name",
                                               all: ["Hong Kong · Premium international route with a long node name"])]
                root.updateFilteredProxyGroups(from: model.proxyGroups, hideHiddenGroups: false, currentMode: .rule)
                try self.render(ScrollView { ProxyTabView(rootViewModel: root) }, model: model,
                                size: CGSize(width: MenuBarLayoutTokens.contentWidth, height: 680), scheme: scheme,
                                path: directory.appendingPathComponent("long-group-\(suffix)"))

                let empty = try NativeRuleTestEnvironment()
                defer { empty.clean() }
                try Data("rules: []\n".utf8).write(to: empty.config)
                empty.model.refreshNativeRuleDocument()
                empty.model.uiLanguage = language
                empty.model.controller = "127.0.0.1:1"
                empty.model.statusBarDisplayMode = .iconOnly
                for tab in RootTab.allCases {
                    empty.model.activeMenuTab = tab
                    let layout = PopoverLayoutModel(maxPanelHeight: 640, preferredPanelHeight: 640)
                    try self.render(MenuBarRootView(), model: empty.model, size: CGSize(width: MenuBarLayoutTokens.panelWidth, height: 640),
                                    scheme: scheme, layout: layout, path: directory.appendingPathComponent("empty-\(tab.rawValue)-\(suffix)"))
                }
            }
        }
    }

    private func populate(_ environment: NativeRuleTestEnvironment) throws {
        let model = environment.model
        model.controller = "127.0.0.1:1" // No test ever discovers or contacts the user's controller.
        model.statusBarDisplayMode = .iconOnly // Hidden previews do not open traffic streams.
        model.apiStatus = .healthy
        model.version = "1.19.31"
        model.tunStack = "system"
        model.isTunEnabled = true
        model.isSystemProxyEnabled = true
        model.systemProxyHelperInstalled = true
        model.systemProxyHelperProcessRunning = true
        model.settingsPort = "7890"
        model.settingsSocksPort = "7891"
        model.settingsMixedPort = "7890"
        let service = NativeProxyProviderService()
        let source = try service.read(configURL: environment.config, data: Data("""
            mixed-port: 7890
            find-process-mode: off
            proxy-providers:
              Personal: {type: http, url: 'https://example.invalid/personal'}
              Travel: {type: http, url: 'https://example.invalid/travel'}
            proxy-groups:
              - {name: 自动选择, type: url-test, include-all-providers: true}
              - {name: 香港优先, type: select, use: [Personal, Travel]}
              - {name: OpenAI, type: select, use: [Personal]}
              - {name: 全球代理, type: select, include-all-providers: true}
            rule-providers:
              Streaming: {type: file, behavior: domain, path: ./streaming.yaml}
            rules:
              - DOMAIN-SUFFIX,example.com,OpenAI # clashbar:custom
              - PROCESS-NAME,Google Chrome,OpenAI # clashbar:custom
              - DOMAIN-SUFFIX,github.com,香港优先
              - DOMAIN,api.openai.com,OpenAI
              - RULE-SET,Streaming,全球代理
              - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
              - GEOIP,CN,DIRECT
              - DOMAIN-SUFFIX,apple.com,DIRECT
              - DOMAIN-SUFFIX,google.com,全球代理
              - DOMAIN-KEYWORD,streaming,全球代理
              - NETWORK,udp,自动选择
              - DST-PORT,443,全球代理
              - AND,((DOMAIN-SUFFIX,example.com),(NETWORK,tcp)),OpenAI
              - MATCH,自动选择
            """.utf8))
        let disabled = try service.prepare(.setEnabled(name: "Travel", enabled: false), in: source)
        try disabled.document.data.write(to: environment.config)
        model.refreshNativeRuleDocument()
        model.defaults.set(environment.config.path, forKey: model.lastSuccessfulConfigPathKey)
        model.rememberAppliedProviderConfig(url: environment.config, data: disabled.document.data)
        let document = try #require(model.nativeRuleDocument)
        let rules: [[String: Any]] = document.entries.map { entry in
            // mihomo returns parsed logical expressions rather than the original YAML payload.
            let payload = entry.syntax?.type == "AND"
                ? "((DomainSuffix,example.com) && (Network,tcp))" : entry.syntax?.payload ?? ""
            return ["index": entry.index, "type": entry.syntax?.type ?? "", "payload": payload,
             "proxy": entry.syntax?.target ?? "", "extra": ["hitCount": (entry.index + 1) * 128,
             "hitAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-180))]]
        }
        model.ruleItems = try JSONDecoder().decode(RulesSummary.self, from: JSONSerialization.data(withJSONObject: ["rules": rules])).rules
        try #require(model.nativeRulesMatchRuntime)
        #expect(model.displayedRuleItems.first?.statistics?.hitCount == 128)
        let provider = try JSONDecoder().decode(ProviderDetail.self, from: Data("""
            {"name":"Personal","vehicleType":"HTTP","updatedAt":"2026-11-23T15:00:00Z",
             "subscriptionInfo":{"upload":1073741824,"download":8589934592,"total":107374182400,"expire":1798070400},
             "proxies":[{"name":"Hong Kong 01","type":"Shadowsocks"},{"name":"Singapore Premium","type":"Trojan"},{"name":"US West 02","type":"VLESS"}]}
            """.utf8))
        let nodes = ["Hong Kong 01", "Singapore Premium", "US West 02", "DIRECT", "Timeout", "Untested"]
        let groups = [
            ProxyGroup(name: "自动选择", type: "URLTest", now: "Hong Kong 01", all: nodes, interval: 120, lazy: true),
            ProxyGroup(name: "香港优先", type: "Selector", now: "Hong Kong 01", all: nodes),
            ProxyGroup(name: "OpenAI", type: "Selector", now: "Singapore Premium", all: nodes),
            ProxyGroup(name: "全球代理", type: "Selector", now: "US West 02", all: nodes),
        ]
        model.applyProxyGroupsResponse(ProxyGroupsResponse(proxies: Dictionary(uniqueKeysWithValues: groups.map { ($0.name, $0) })),
                                       proxyProviders: ["Personal": provider])
        model.applyMeasuredNodeDelays(["Hong Kong 01": 42, "Singapore Premium": 180, "US West 02": 420, "DIRECT": 1, "Timeout": 0],
                                     testURL: "https://example.invalid/generate_204", measuredAt: Date().addingTimeInterval(-180))
        model.trafficStore.traffic = TrafficSnapshot(up: 524288, down: 24_000_000)
        model.trafficStore.displayUpTotal = 1_073_741_824
        model.trafficStore.displayDownTotal = 8_589_934_592
        model.trafficStore.memory = MemorySnapshot(inuse: 67_108_864)
        model.trafficStore.trafficHistoryUp = (0..<60).map { Int64((sin(Double($0) * 0.35) + 1) * 700_000) }
        model.trafficStore.trafficHistoryDown = (0..<60).map { Int64((sin(Double($0) * 0.2) + 1) * 12_000_000) }
        let hosts = ["api.example.com", "dns.example.com", "github.com", "www.apple.com", "streaming.example.com"]
        var connections: [ConnectionSummary] = []
        for index in hosts.indices {
            let metadata = ConnectionMetadata(network: index == 1 ? "udp" : "tcp", sourceIP: "127.0.0.1",
                destinationIP: "203.0.113.10", host: hosts[index], process: "Google Chrome",
                processPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", sourcePort: "52123",
                destinationPort: "443", dnsMode: "fake-ip", sniffHost: "api.example.com", inboundName: "Mixed")
            let count = Int64(index + 1)
            connections.append(ConnectionSummary(id: "visual-connection-\(index)", upload: 1024 * count,
                download: 1_048_576 * count, start: "2026-11-23T15:58:00Z", rule: "DomainSuffix",
                rulePayload: "example.com", chains: [nodes[index % 3], "OpenAI"], metadata: metadata))
        }
        model.connectionsStore.connections = connections
        model.connectionsStore.connectionsCount = model.connectionsStore.connections.count
        model.logsStore.errorLogs = [
            AppErrorLogEntry(source: .clashbar, level: "info", message: "Configuration loaded. Mode: rule."),
            AppErrorLogEntry(source: .mihomo, level: "info", message: "[TCP] 127.0.0.1:52123 --> api.example.com:443 match DomainSuffix(example.com) using OpenAI[Singapore Premium]"),
            AppErrorLogEntry(source: .mihomo, level: "warning", message: "[UDP] DNS query timed out; retrying with the next upstream."),
            AppErrorLogEntry(source: .clashbar, level: "error", message: "Subscription update failed. The previous configuration is still available."),
        ]
    }

    private func componentGallery(language: AppLanguage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            AppSectionHeader(L10n.t("ui.diagnostics.current_selection", language: language))
            HStack(spacing: 12) {
                IconBadge(symbol: "network", tint: .blue)
                Text("ClashBar · 原生面板").font(.app(size: 15, weight: .semibold))
            }.appSectionCard(opaque: true)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                ForEach([1, 149, 150, 350, 351, 0], id: \.self) { value in
                    LatencyPillBadge(value: value, text: L10n.t(value == 0 ? "ui.common.timeout" : "ui.common.latency_ms", language: language, value))
                }
            }.appSectionCard(opaque: true)
            HStack { SemanticTag(text: "TCP", tint: .blue); SemanticTag(text: "UDP", tint: .teal); SemanticTag(text: "DOMAIN-SUFFIX", tint: .indigo) }
                .appSectionCard(opaque: true)
            Text("DOMAIN-SUFFIX,example.com,OpenAI").appCodeBlock()
            SheetNote(text: L10n.t("ui.quick_rule.subscription_hint", language: language), tint: .orange, symbol: "exclamationmark.triangle")
                .appSectionCard(opaque: true)
        }.padding(12)
    }

    private func nodeMenu(language: AppLanguage) -> some View {
        AttachedPopoverSurface(width: 320, maxHeight: 350) {
            AppSectionHeader("OpenAI", symbol: "point.3.connected.trianglepath.dotted", count: "6")
            SheetNote(text: L10n.t("ui.diagnostics.popover_note", language: language))
                .padding(.bottom, 8)
            ForEach(Array(zip(["Hong Kong 01", "Singapore Premium", "US West 02", "Timeout", "Untested", "Premium international route with a very long node name"],
                              [42, 180, 420, 0, -1, 149])), id: \.0) { name, delay in
                let samples = delay < 0 ? [] : [delay]
                let text = L10n.t(delay < 0 ? "ui.common.na" : delay == 0 ? "ui.common.timeout" : "ui.common.latency_ms",
                                  language: language, delay)
                ProxyGroupPopoverNodeItem(title: name, typeText: "Trojan", delayText: text, delaySamples: samples,
                                          latestSample: delay < 0 ? nil : ProxyLatencySample(delay: delay, time: Date().addingTimeInterval(-180)),
                                          language: language, isTesting: name == "Untested", selected: name == "Singapore Premium",
                                          testLatencyLabel: L10n.t("ui.action.test_latency", language: language),
                                          onTestLatency: {}, action: {})
            }
        }
    }

    private func render<Content: View>(_ content: Content, model: AppViewModel, size: CGSize, scheme: ColorScheme,
                                      layout: PopoverLayoutModel? = nil, scrollOffset: CGFloat = 0, path: URL) throws {
        let layoutModel = layout ?? PopoverLayoutModel(maxPanelHeight: size.height, preferredPanelHeight: size.height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        defer { window.contentView = nil; window.close() }
        let view = content.environmentObject(model).environmentObject(model.proxyStore).environmentObject(model.trafficStore)
            .environmentObject(model.connectionsStore).environmentObject(model.logsStore).environmentObject(model.remoteMachineStore)
            .environmentObject(layoutModel).environment(\.proxyGroupIconCache, model.proxyGroupIconCache)
            .environment(\.colorScheme, scheme)
            .defaultAppStorage(model.defaults)
            .frame(width: size.width, height: layout?.resolvedPanelHeight ?? size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.18))
        if let layout {
            window.setContentSize(CGSize(width: size.width, height: layout.resolvedPanelHeight))
            host.frame = NSRect(x: 0, y: 0, width: size.width, height: layout.resolvedPanelHeight)
        }
        host.layoutSubtreeIfNeeded()
        if scrollOffset > 0, let scroll = self.scrollViews(in: host).filter({ ($0.documentView?.frame.height ?? 0) > $0.contentSize.height }).first {
            let limit = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentSize.height)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: min(scrollOffset, limit)))
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.10))
        }
        host.layoutSubtreeIfNeeded()
        #expect(host.bounds.width == size.width && host.bounds.height > 0)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: path)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { self.scrollViews(in: $0) }
    }
}
