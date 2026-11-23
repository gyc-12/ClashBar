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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if self.inspectedGroup != nil {
                    Button { self.inspectedGroup = nil } label: { Image(systemName: "chevron.left") }
                        .help(self.tr("ui.diagnostics.connection_details"))
                }
                Text(self.tr("ui.diagnostics.connection_details")).font(.headline)
                Spacer()
                Button(self.tr("ui.action.close")) { self.dismiss() }
            }
            if let name = self.inspectedGroup {
                ProxyGroupDetailView(name: name, embedded: true)
                    .environmentObject(self.appViewModel).environmentObject(self.proxyStore)
            } else {
                ScrollView {
                    self.overview
                }
            }
        }.padding(16).frame(width: 460, height: 620)
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
            if self.live == nil {
                Text(self.tr("ui.diagnostics.connection_snapshot")).font(.caption).foregroundStyle(.secondary)
            }
            DiagnosticField(title: self.tr("ui.diagnostics.host"), value: metadata?.host ?? "—")
            DiagnosticField(title: self.tr("ui.diagnostics.sniff_host"), value: metadata?.sniffHost ?? "—")
            HStack(alignment: .top) {
                DiagnosticField(title: self.tr("ui.diagnostics.source"), value: self.endpoint(metadata?.sourceIP, port: metadata?.sourcePort))
                DiagnosticField(title: self.tr("ui.diagnostics.destination"), value: self.endpoint(metadata?.destinationIP, port: metadata?.destinationPort))
            }
            HStack {
                DiagnosticField(title: self.tr("ui.diagnostics.network"), value: metadata?.network?.uppercased() ?? "—")
                DiagnosticField(title: self.tr("ui.diagnostics.dns_mode"), value: metadata?.dnsMode ?? "—")
            }
            DiagnosticField(title: self.tr("ui.diagnostics.process"), value: metadata?.process ?? "—")
            DiagnosticField(title: self.tr("ui.diagnostics.process_path"), value: metadata?.processPath ?? "—")
            if let process = ApplicationRoutingCandidate.from(connection: connection) {
                Button(self.tr("ui.app_rule.for_process")) {
                    Task {
                        do { self.applicationContext = try await self.appViewModel.applicationRuleContext(selected: process) }
                        catch { self.applicationError = self.appViewModel.quickRuleErrorText(error) }
                    }
                }.disabled(!self.appViewModel.canEditApplicationRules)
                if self.appViewModel.isRemoteTarget { self.noteLocalOnly }
                if let applicationError { Text(applicationError).font(.caption).foregroundStyle(.red) }
            }
            if metadata?.process == nil && metadata?.processPath == nil {
                Text(self.tr("ui.diagnostics.process_note")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                DiagnosticField(title: self.tr("ui.diagnostics.started"), value: ValueFormatter.dateTimeFromISO(connection.start))
                DiagnosticField(title: self.tr("ui.diagnostics.traffic"), value: "↑ \(ValueFormatter.bytesCompactNoSpace(connection.upload ?? 0)) · ↓ \(ValueFormatter.bytesCompactNoSpace(connection.download ?? 0))")
            }
            DiagnosticField(title: self.tr("ui.diagnostics.inbound"), value: metadata?.inboundName ?? "—")
            Divider()
            DiagnosticField(title: self.tr("ui.diagnostics.matched_rule"), value: [connection.rule, connection.rulePayload].compactMap { $0 }.joined(separator: " · "))
            Button(self.tr(candidates.count == 1 ? "ui.diagnostics.open_rule" : "ui.diagnostics.rule_candidates", candidates.count)) {
                self.appViewModel.navigateToConnectionRules(connection)
            }.disabled(candidates.isEmpty)
            if !self.appViewModel.isRemoteTarget && !self.appViewModel.nativeRulesMatchRuntime {
                Text(self.tr("ui.diagnostics.runtime_only_rules")).font(.caption).foregroundStyle(.secondary)
            }
            if candidates.count > 1 {
                Text(self.tr("ui.diagnostics.ambiguous_rule")).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text(self.tr("ui.diagnostics.actual_chain")).font(.subheadline.weight(.semibold))
            Text(self.tr("ui.diagnostics.chain_note")).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(chain.enumerated()), id: \.offset) { index, name in
                HStack(spacing: 8) {
                    Text("\(index + 1)").font(.caption).foregroundStyle(.secondary)
                    if self.proxyStore.proxyGroups.contains(where: { $0.name == name }) {
                        Button(name) { self.inspectedGroup = name }.buttonStyle(.link)
                    } else { Text(name).font(.system(size: 12)).textSelection(.enabled) }
                    Spacer()
                    let samples = self.proxyStore.proxyLatencyHistory[name] ?? []
                    if let sample = samples.last {
                        VStack(alignment: .trailing) {
                            Text(sample.delay == 0 ? self.tr("ui.common.timeout") : self.tr("ui.common.latency_ms", sample.delay)).font(.caption)
                            LatencyAgeView(sample: sample, language: self.language)
                        }
                    }
                }
            }
            DiagnosticField(title: "ID", value: connection.id)
        }.padding(.trailing, 6)
    }

    private func endpoint(_ ip: String?, port: String?) -> String {
        guard let ip else { return "—" }
        guard let port else { return ip }
        return ip.contains(":") ? "[\(ip)]:\(port)" : "\(ip):\(port)"
    }
    private var noteLocalOnly: some View { Text(self.tr("ui.quick_rule.local_only")).font(.caption).foregroundStyle(.secondary) }
}
