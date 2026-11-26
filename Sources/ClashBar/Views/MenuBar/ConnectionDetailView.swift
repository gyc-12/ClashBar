import SwiftUI

struct ConnectionDetailView: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    @EnvironmentObject var connectionsStore: ConnectionsStore
    @EnvironmentObject var proxyStore: ProxyStore
    @Environment(\.dismiss) private var dismiss
    let snapshot: ConnectionSummary
    @State private var inspectedGroup: String?
    @State private var applicationContext: ApplicationRuleEditorContext?
    @State private var applicationError: String?
    private var live: ConnectionSummary? { self.connectionsStore.connections.first { $0.id == self.snapshot.id } }
    private var connection: ConnectionSummary { self.live ?? self.snapshot }

    var body: some View {
        ModalSheetContainer(title: self.tr("ui.diagnostics.connection_details"),
                            subtitle: self.connection.metadata?.host ?? self.connection.metadata?.destinationIP ?? self.connection.id,
                            symbol: "link", width: MenuBarLayoutTokens.Sheet.wideWidth,
                            backLabel: self.tr("ui.diagnostics.connection_details"),
                            onBack: self.inspectedGroup == nil ? nil : { self.inspectedGroup = nil }) {
            if let name = self.inspectedGroup {
                ProxyGroupDetailView(name: name, embedded: true)
                    .environmentObject(self.appViewModel).environmentObject(self.proxyStore)
            } else {
                self.overview
            }
        } footer: {
            HStack {
                Spacer()
                Button(self.tr("ui.action.close")) { self.dismiss() }.keyboardShortcut(.defaultAction)
                    .appBorderedButtonStyle(prominent: true)
            }
        }
        .sheet(item: self.$applicationContext) { context in
            ApplicationRuleEditorView(context: context).environmentObject(self.appViewModel)
        }
        .onAppear {
            self.appViewModel.refreshNativeRuleDocument()
            if self.appViewModel.isRuntimeRunning {
                Task { await self.appViewModel.refreshProxyGroups(); await self.appViewModel.refreshProvidersAndRules() }
            }
        }
    }

    private var overview: some View {
        let connection = self.connection
        let metadata = connection.metadata
        let candidates = self.appViewModel.connectionRuleCandidates(connection)
        let chain = Array((connection.chains ?? []).reversed())
        return VStack(alignment: .leading, spacing: 12) {
            if self.live == nil { SheetNote(text: self.tr("ui.diagnostics.connection_snapshot"), symbol: "clock") }
            VStack(alignment: .leading, spacing: 12) {
                DiagnosticField(title: self.tr("ui.diagnostics.host"), value: metadata?.host ?? "—")
                DiagnosticField(title: self.tr("ui.diagnostics.sniff_host"), value: metadata?.sniffHost ?? "—")
                HStack(alignment: .top, spacing: 12) {
                    DiagnosticField(title: self.tr("ui.diagnostics.source"), value: self.endpoint(metadata?.sourceIP, port: metadata?.sourcePort))
                    DiagnosticField(title: self.tr("ui.diagnostics.destination"), value: self.endpoint(metadata?.destinationIP, port: metadata?.destinationPort))
                }
                HStack(alignment: .top, spacing: 12) {
                    DiagnosticField(title: self.tr("ui.diagnostics.network"), value: metadata?.network?.uppercased() ?? "—")
                    DiagnosticField(title: self.tr("ui.diagnostics.dns_mode"), value: metadata?.dnsMode ?? "—")
                }
            }.appSectionCard(padding: 12)
            VStack(alignment: .leading, spacing: 12) {
                DiagnosticField(title: self.tr("ui.diagnostics.process"), value: metadata?.process ?? "—")
                DiagnosticField(title: self.tr("ui.diagnostics.process_path"), value: metadata?.processPath ?? "—")
                if let process = ApplicationRoutingCandidate.from(connection: connection) {
                    Button(self.tr("ui.app_rule.for_process")) {
                        Task {
                            do { self.applicationContext = try await self.appViewModel.applicationRuleContext(selected: process) }
                            catch { self.applicationError = self.appViewModel.quickRuleErrorText(error) }
                        }
                    }.appBorderedButtonStyle().disabled(!self.appViewModel.canEditApplicationRules)
                    if self.appViewModel.isRemoteTarget { self.noteLocalOnly }
                    if let applicationError { SheetNote(text: applicationError, tint: self.nativeCritical) }
                }
                if metadata?.process == nil && metadata?.processPath == nil { SheetNote(text: self.tr("ui.diagnostics.process_note")) }
                HStack(alignment: .top, spacing: 12) {
                    DiagnosticField(title: self.tr("ui.diagnostics.started"), value: ValueFormatter.dateTimeFromISO(connection.start))
                    DiagnosticField(title: self.tr("ui.diagnostics.traffic"), value: "↑ \(ValueFormatter.bytesCompactNoSpace(connection.upload ?? 0)) · ↓ \(ValueFormatter.bytesCompactNoSpace(connection.download ?? 0))")
                }
                DiagnosticField(title: self.tr("ui.diagnostics.inbound"), value: metadata?.inboundName ?? "—")
            }.appSectionCard(padding: 12)
            VStack(alignment: .leading, spacing: 10) {
                DiagnosticField(title: self.tr("ui.diagnostics.matched_rule"), value: [connection.rule, connection.rulePayload].compactMap { $0 }.joined(separator: " · "))
                Button(self.tr(candidates.count == 1 ? "ui.diagnostics.open_rule" : "ui.diagnostics.rule_candidates", candidates.count)) {
                    self.appViewModel.navigateToConnectionRules(connection)
                }.appBorderedButtonStyle().disabled(candidates.isEmpty)
                if !self.appViewModel.isRemoteTarget && !self.appViewModel.nativeRulesMatchRuntime {
                    SheetNote(text: self.tr("ui.diagnostics.runtime_only_rules"))
                }
                if candidates.count > 1 { SheetNote(text: self.tr("ui.diagnostics.ambiguous_rule")) }
            }.appSectionCard(padding: 12)
            VStack(alignment: .leading, spacing: 10) {
                AppSectionHeader(self.tr("ui.diagnostics.actual_chain"), symbol: "point.3.connected.trianglepath.dotted")
                SheetNote(text: self.tr("ui.diagnostics.chain_note"))
                ForEach(Array(chain.enumerated()), id: \.offset) { index, name in
                    HStack(spacing: 8) {
                        SemanticTag(text: "\(index + 1)", tint: self.nativeIndigo)
                        if self.proxyStore.proxyGroups.contains(where: { $0.name == name }) {
                            Button(name) { self.inspectedGroup = name }.buttonStyle(.link)
                        } else { Text(name).textSelection(.enabled) }
                        Spacer(minLength: 4)
                        if let sample = self.proxyStore.proxyLatencyHistory[name]?.last {
                            VStack(alignment: .trailing, spacing: 2) {
                                LatencyPillBadge(value: sample.delay,
                                                 text: self.tr(sample.delay == 0 ? "ui.common.timeout" : "ui.common.latency_ms", sample.delay))
                                LatencyAgeView(sample: sample, language: self.language)
                            }
                        }
                    }
                    .font(.app(size: MenuBarLayoutTokens.FontSize.callout))
                }
            }.appSectionCard(padding: 12)
            DiagnosticField(title: "ID", value: connection.id).appSectionCard(padding: 12)
        }
    }

    private func endpoint(_ ip: String?, port: String?) -> String {
        guard let ip else { return "—" }
        guard let port else { return ip }
        return ip.contains(":") ? "[\(ip)]:\(port)" : "\(ip):\(port)"
    }
    private var noteLocalOnly: some View { SheetNote(text: self.tr("ui.quick_rule.local_only")) }
}
