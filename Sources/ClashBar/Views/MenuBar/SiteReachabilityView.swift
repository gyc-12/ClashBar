import SwiftUI

struct SiteReachabilityView: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    @EnvironmentObject var proxyStore: ProxyStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected = ""

    private var groups: [ProxyGroup] { proxyStore.proxyGroups }
    private var group: ProxyGroup? { groups.first { $0.name == selected } ?? groups.first }

    var body: some View {
        ModalSheetContainer(title: tr("ui.sites.title"), subtitle: nil, symbol: "globe") {
            SiteCheckRows(group: group?.name, proxyHost: appViewModel.controllerHost(from: appViewModel.controller),
                          client: try? appViewModel.clientOrThrow()) {
                if let group {
                    Picker(tr("ui.sites.route"), selection: Binding(get: { group.name }, set: { selected = $0 })) {
                        ForEach(groups, id: \.name) { Text(verbatim: $0.name).tag($0.name) }
                    }
                } else { SheetNote(text: tr("ui.empty.proxy_groups")) }
            }
            .id([appViewModel.controller, appViewModel.currentMode.rawValue, String(appViewModel.proxyProviderPresentationGeneration)]
                + (group.map { appViewModel.proxySelectionChain(startingAt: $0.name) } ?? []))
        } footer: {
            HStack { Spacer(); Button(tr("ui.action.close")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }
    }
}

private struct SiteCheckRows<RoutePicker: View>: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    let group: String?
    let proxyHost: String?
    let client: (any MihomoAPITransporting)?
    @ViewBuilder let routePicker: () -> RoutePicker
    @State private var run: UUID?
    @State private var results: [ReachabilitySite: SiteCheckResult] = [:]

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                AppSectionHeader(tr("ui.sites.region_title"), symbol: "globe")
                row(.gemini)
                row(.chatGPTRegion)
                SheetNote(text: tr("ui.sites.region_note"))
            }.appSectionCard(padding: 12)
            VStack(alignment: .leading, spacing: 10) {
                routePicker()
                SheetNote(text: tr("ui.sites.note"))
                row(.chatGPT)
                row(.youtube)
            }.appSectionCard(padding: 12)
            Button(tr("ui.sites.check")) { results = [:]; run = UUID() }
                .disabled(run != nil && results.count < ReachabilitySite.allCases.count)
        }
        .task(id: run) {
            guard run != nil else { return }
            await withTaskGroup(of: (ReachabilitySite, SiteCheckResult).self) { tasks in
                for site in ReachabilitySite.allCases {
                    tasks.addTask { [group, client, proxyHost] in
                        guard let client else { return (site, .controllerError) }
                        return (site, await site.check(group: group, client: client, proxyHost: proxyHost))
                    }
                }
                for await (site, result) in tasks where !Task.isCancelled { results[site] = result }
            }
        }
    }

    private func row(_ site: ReachabilitySite) -> some View {
        HStack {
            Text(verbatim: site.displayName).help(site.url)
            Spacer()
            switch results[site] {
            case let .regionSupported(code): Text(tr("ui.sites.region_supported", code)).foregroundStyle(nativePositive)
            case let .regionRestricted(code): Text(code.map { tr("ui.sites.region_blocked_code", $0) } ?? tr("ui.sites.region_blocked")).foregroundStyle(nativeCritical)
            case .indeterminate: Text(tr("ui.sites.region_unknown")).foregroundStyle(nativeWarning)
            case .proxyUnavailable: Text(tr("ui.sites.proxy_unavailable")).foregroundStyle(nativeWarning)
            case .proxyAuthRequired: Text(tr("ui.sites.proxy_auth")).foregroundStyle(nativeWarning)
            case let .reachable(delay): Text(tr("ui.sites.reachable", delay)).foregroundStyle(nativePositive)
            case .timeout: Text(tr("ui.common.timeout")).foregroundStyle(nativeWarning)
            case .unreachable: Text(tr("ui.sites.unreachable")).foregroundStyle(nativeWarning)
            case .controllerError: Text(tr("ui.sites.controller_error")).foregroundStyle(nativeWarning)
            case nil: if run != nil { ProgressView().controlSize(.small) } else { Text(tr("ui.sites.not_tested")).foregroundStyle(.secondary) }
            }
        }
    }
}
