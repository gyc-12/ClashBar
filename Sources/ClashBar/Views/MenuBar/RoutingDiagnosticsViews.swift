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
                .font(.system(size: 9))
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(self.name).font(.headline).textSelection(.enabled)
                Spacer()
                if !self.embedded { Button(self.tr("ui.action.close")) { self.dismiss() } }
            }
            if let group {
                let settings = self.appViewModel.healthcheckSettings(for: group)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        DiagnosticField(title: self.tr("ui.diagnostics.current_selection"), value: group.now ?? "—")
                        DiagnosticField(title: self.tr("ui.diagnostics.test_url"), value: settings.url ?? self.tr("ui.diagnostics.default_test_url", self.appViewModel.defaultHealthcheckURL))
                        HStack {
                            DiagnosticField(title: self.tr("ui.diagnostics.interval"), value: settings.interval.map { self.tr("ui.diagnostics.interval_seconds", $0) } ?? self.tr("ui.common.unknown"))
                            Spacer()
                            DiagnosticField(title: "lazy", value: settings.lazy.map { self.tr($0 ? "ui.diagnostics.lazy_on" : "ui.diagnostics.lazy_off") } ?? self.tr("ui.common.unknown"))
                        }
                        if ["urltest", "url-test", "fallback"].contains(group.type?.lowercased() ?? "") {
                            Text(self.tr("ui.diagnostics.auto_test_note")).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(self.tr("ui.diagnostics.schedule_note")).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(self.tr("ui.diagnostics.refresh_data")) { Task { await self.appViewModel.refreshProxyGroups() } }
                            Button(self.tr("ui.diagnostics.retest")) { Task { await self.appViewModel.refreshGroupLatency(group) } }
                                .disabled(self.proxyStore.groupLatencyLoading.contains(group.name))
                            if self.proxyStore.groupLatencyLoading.contains(group.name) { ProgressView().controlSize(.small) }
                        }
                        Divider()
                        ForEach(group.all, id: \.self) { node in
                            let samples = self.appViewModel.latencySamples(group: group.name, node: node)
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
                                }.buttonStyle(.plain).disabled(self.switching || !self.isSelectable(group))
                                    .help(self.tr("ui.diagnostics.select_node"))
                                Text(node).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Button {
                                    self.selectedHistoryNode = self.selectedHistoryNode == node ? nil : node
                                } label: {
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(self.appViewModel.delayText(group: group.name, node: node)).font(.caption)
                                        LatencyAgeView(sample: samples.last, language: self.language, interval: settings.interval)
                                    }
                                }.buttonStyle(.plain).help(self.tr("ui.diagnostics.history"))
                                Button {
                                    Task { await self.appViewModel.refreshProxyLatency(group: group.name, node: node) }
                                } label: { Image(systemName: "gauge") }
                                    .buttonStyle(.plain).help(self.tr("ui.diagnostics.retest"))
                                    .disabled(self.appViewModel.isProxyLatencyTesting(group: group.name, node: node))
                            }
                            if self.selectedHistoryNode == node {
                                LatencyHistoryView(samples: samples, language: self.language)
                            }
                        }
                    }
                }
            } else {
                Text(self.tr("ui.diagnostics.group_unavailable")).foregroundStyle(.secondary)
            }
        }
        .padding(self.embedded ? 0 : 16)
        .frame(width: self.embedded ? nil : 460, height: self.embedded ? nil : 560)
        .onAppear { self.appViewModel.refreshNativeRuleDocument() }
    }

    private func isSelectable(_ group: ProxyGroup) -> Bool {
        ["selector", "select", "urltest", "url-test", "fallback"].contains(group.type?.lowercased() ?? "")
    }
}

struct LatencyHistoryView: View {
    let samples: [ProxyLatencySample]
    let language: AppLanguage
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("ui.diagnostics.history", language: self.language)).font(.caption.weight(.semibold))
            if self.samples.isEmpty { Text("—") }
            ForEach(Array(self.samples.enumerated()), id: \.offset) { _, sample in
                HStack {
                    Text(sample.time.map(ValueFormatter.dateTime) ?? L10n.t("ui.diagnostics.time_unknown", language: self.language))
                    Spacer()
                    Text(sample.delay == 0 ? L10n.t("ui.common.timeout", language: self.language) : L10n.t("ui.common.latency_ms", language: self.language, sample.delay))
                }
                if let url = sample.testURL { Text(url).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }.font(.caption).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct DiagnosticField: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(self.title).font(.caption).foregroundStyle(.secondary)
            Text(self.value).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
