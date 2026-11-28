import SwiftUI

struct LatencyAgeView: View {
    let sample: ProxyLatencySample?
    let language: AppLanguage
    var interval: Int? = nil
    var showsStaleness = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let stale = self.showsStaleness && self.sample?.isStale(now: context.date, interval: self.interval) == true
            Text(self.text(now: context.date))
                .font(.app(size: MenuBarLayoutTokens.FontSize.micro))
                .foregroundStyle(stale ? Color.orange : Color.secondary)
                .lineLimit(1)
                .help(self.sample?.time.map(ValueFormatter.dateTime) ?? L10n.t("ui.diagnostics.time_unknown", language: self.language))
        }
    }

    func text(now: Date) -> String {
        guard let time = self.sample?.time else { return L10n.t("ui.diagnostics.time_unknown", language: self.language) }
        let seconds = max(0, Int(now.timeIntervalSince(time)))
        let key: String
        let value: Int
        if seconds < 60 { key = "ui.diagnostics.age_seconds"; value = seconds }
        else if seconds < 3600 { key = "ui.diagnostics.age_minutes"; value = seconds / 60 }
        else if seconds < 86400 { key = "ui.diagnostics.age_hours"; value = seconds / 3600 }
        else { key = "ui.diagnostics.age_days"; value = seconds / 86400 }
        let age = L10n.t(key, language: self.language, value)
        return self.showsStaleness && self.sample?.isStale(now: now, interval: self.interval) == true
            ? L10n.t("ui.diagnostics.stale", language: self.language, age) : age
    }
}

struct ProxyGroupDetailView: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    @EnvironmentObject var proxyStore: ProxyStore
    @Environment(\.dismiss) private var dismiss
    let name: String
    var embedded = false
    @State private var selectedHistoryNode: String?
    @State private var switching = false

    private var group: ProxyGroup? { self.proxyStore.proxyGroups.first { $0.name == self.name } }

    var body: some View {
        Group {
            if self.embedded {
                VStack(alignment: .leading, spacing: 10) {
                    AppSectionHeader(self.name, symbol: "point.3.connected.trianglepath.dotted")
                    self.groupContent
                }
            } else {
                ModalSheetContainer(title: self.name, subtitle: self.tr("ui.diagnostics.group_details"),
                                    symbol: "point.3.connected.trianglepath.dotted", width: MenuBarLayoutTokens.Sheet.wideWidth) {
                    self.groupContent
                } footer: {
                    HStack {
                        Spacer()
                        Button(self.tr("ui.action.close")) { self.dismiss() }.keyboardShortcut(.defaultAction)
                            .appBorderedButtonStyle(prominent: true)
                    }
                }
            }
        }
        .font(.app(size: MenuBarLayoutTokens.FontSize.body))
        .onAppear { self.appViewModel.refreshNativeRuleDocument() }
    }

    @ViewBuilder
    private var groupContent: some View {
        if let group {
            let settings = self.appViewModel.healthcheckSettings(for: group)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    DiagnosticField(title: self.tr("ui.diagnostics.current_selection"), value: group.now ?? "—", monospaced: false)
                    DiagnosticField(title: self.tr("ui.diagnostics.test_url"), value: settings.url ?? self.tr("ui.diagnostics.default_test_url", self.appViewModel.defaultHealthcheckURL))
                    HStack(alignment: .top, spacing: 12) {
                        DiagnosticField(title: self.tr("ui.diagnostics.interval"),
                                        value: settings.interval.map { self.tr("ui.diagnostics.interval_seconds", $0) } ?? self.tr("ui.common.unknown"))
                        DiagnosticField(title: "lazy", value: settings.lazy.map { self.tr($0 ? "ui.diagnostics.lazy_on" : "ui.diagnostics.lazy_off") } ?? self.tr("ui.common.unknown"), monospaced: false)
                    }
                    if ["urltest", "url-test", "fallback"].contains(group.type?.lowercased() ?? "") {
                        SheetNote(text: self.tr("ui.diagnostics.auto_test_note"))
                    }
                    SheetNote(text: self.tr("ui.diagnostics.schedule_note"))
                    HStack(spacing: 8) {
                        Button(self.tr("ui.diagnostics.refresh_data")) { Task { await self.appViewModel.refreshProxyGroups() } }
                            .appBorderedButtonStyle()
                        Button(self.tr("ui.diagnostics.retest")) { Task { await self.appViewModel.refreshGroupLatency(group) } }
                            .appBorderedButtonStyle().disabled(self.proxyStore.groupLatencyLoading.contains(group.name))
                        if self.proxyStore.groupLatencyLoading.contains(group.name) { ProgressView().controlSize(.small) }
                    }
                }.appSectionCard(padding: 12)
                VStack(alignment: .leading, spacing: 8) {
                    AppSectionHeader(self.tr("ui.section.proxy_groups"), count: "\(group.all.count)")
                    let folded = appViewModel.foldedNodes(in: group)
                    FoldableNodesList(nodes: group.all, folded: folded, title: tr("ui.groups.timeouts", folded.count), emptyText: tr("ui.common.na")) { node in
                        self.nodeRow(node, group: group, interval: settings.interval)
                    }
                }.appSectionCard(padding: 12)
            }
        } else {
            self.emptyCard(self.tr("ui.diagnostics.group_unavailable"))
        }
    }

    private func nodeRow(_ node: String, group: ProxyGroup, interval: Int?) -> some View {
        let samples = self.appViewModel.latencySamples(group: group.name, node: node)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    guard !self.switching else { return }
                    self.switching = true
                    Task {
                        await self.appViewModel.switchProxy(group: group.name, target: node)
                        self.switching = false
                    }
                } label: {
                    Image(systemName: node == group.now ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(node == group.now ? self.nativeAccent : self.nativeSecondaryLabel)
                        .frame(width: 22, height: 30)
                        .contentShape(RoundedRectangle(cornerRadius: MenuBarLayoutTokens.cornerRadius, style: .continuous))
                }
                .buttonStyle(.plain).disabled(self.switching || !self.isSelectable(group))
                .help(self.tr("ui.diagnostics.select_node"))
                .accessibilityLabel(self.tr("ui.diagnostics.select_node") + ": " + node)
                Text(node).lineLimit(1).truncationMode(.middle).font(.app(size: MenuBarLayoutTokens.FontSize.callout))
                Spacer(minLength: 4)
                Button { self.selectedHistoryNode = self.selectedHistoryNode == node ? nil : node } label: {
                    VStack(alignment: .trailing, spacing: 2) {
                        LatencyPillBadge(value: samples.last?.delay, text: self.appViewModel.delayText(group: group.name, node: node))
                        LatencyAgeView(sample: samples.last, language: self.language, interval: interval)
                    }
                }
                .buttonStyle(.plain).help(self.tr("ui.diagnostics.history"))
                .accessibilityLabel(node + ": " + self.tr("ui.diagnostics.history"))
                self.compactAsyncIconButton(symbol: "gauge", label: self.tr("ui.diagnostics.retest"), tint: self.nativeTeal,
                                            isLoading: self.appViewModel.isProxyLatencyTesting(group: group.name, node: node), size: 24) {
                    await self.appViewModel.refreshProxyLatency(group: group.name, node: node)
                }
            }
            if self.selectedHistoryNode == node { LatencyHistoryView(samples: samples, language: self.language) }
        }
    }

    private func isSelectable(_ group: ProxyGroup) -> Bool {
        ["selector", "select", "urltest", "url-test", "fallback"].contains(group.type?.lowercased() ?? "")
    }
}

struct LatencyHistoryView: View {
    let samples: [ProxyLatencySample]
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AppSectionHeader(L10n.t("ui.diagnostics.history", language: self.language))
            if self.samples.isEmpty { Text("—").foregroundStyle(.secondary) }
            ForEach(Array(self.samples.enumerated()), id: \.offset) { _, sample in
                HStack(spacing: 8) {
                    Text(sample.time.map(ValueFormatter.dateTime) ?? L10n.t("ui.diagnostics.time_unknown", language: self.language))
                        .font(.appMono(size: MenuBarLayoutTokens.FontSize.caption))
                    Spacer(minLength: 0)
                    LatencyPillBadge(value: sample.delay,
                                     text: L10n.t(sample.delay == 0 ? "ui.common.timeout" : "ui.common.latency_ms", language: self.language, sample.delay))
                }
                if let url = sample.testURL {
                    Text(url).font(.appMono(size: MenuBarLayoutTokens.FontSize.caption)).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.appSectionCard(padding: 8)
    }
}

struct DiagnosticField: View {
    let title: String
    let value: String
    var monospaced = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.title).font(.app(size: MenuBarLayoutTokens.FontSize.subheadline, weight: .medium)).foregroundStyle(.secondary)
            Text(self.value)
                .font(self.monospaced ? .appMono(size: MenuBarLayoutTokens.FontSize.callout) : .app(size: MenuBarLayoutTokens.FontSize.callout))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
