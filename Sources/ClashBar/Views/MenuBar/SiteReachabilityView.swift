import SwiftUI

struct SiteReachabilityView: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    @EnvironmentObject var proxyStore: ProxyStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected = ""
    @State private var runRequest: UUID?
    @State private var isChecking = false

    private var groups: [ProxyGroup] { proxyStore.proxyGroups }
    private var group: ProxyGroup? { groups.first { $0.name == selected } ?? groups.first }

    var body: some View {
        ModalSheetContainer(
            title: tr("ui.sites.title"),
            subtitle: nil,
            symbol: "globe",
            width: MenuBarLayoutTokens.Sheet.wideWidth,
            height: MenuBarLayoutTokens.Sheet.tallHeight)
        {
            SiteCheckRows(
                group: group?.name,
                proxyHost: appViewModel.controllerHost(from: appViewModel.controller),
                client: try? appViewModel.clientOrThrow(),
                runRequest: runRequest,
                isChecking: $isChecking)
            {
                if let group {
                    Picker(tr("ui.sites.route"), selection: Binding(get: { group.name }, set: { selected = $0 })) {
                        ForEach(groups, id: \.name) { Text(verbatim: $0.name).tag($0.name) }
                    }
                } else { SheetNote(text: tr("ui.empty.proxy_groups")) }
            }
            .id([appViewModel.controller, appViewModel.currentMode.rawValue, String(appViewModel.proxyProviderPresentationGeneration)]
                + (group.map { appViewModel.proxySelectionChain(startingAt: $0.name) } ?? []))
        } footer: {
            HStack(spacing: 8) {
                Button(tr("ui.sites.check")) {
                    isChecking = true
                    runRequest = UUID()
                }
                .appBorderedButtonStyle(prominent: true)
                .disabled(isChecking)
                if isChecking { ProgressView().controlSize(.small) }
                Spacer()
                Button(tr("ui.action.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .appBorderedButtonStyle()
            }
        }
    }
}

private struct SiteCheckRows<RoutePicker: View>: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    let group: String?
    let proxyHost: String?
    let client: (any MihomoAPITransporting)?
    let runRequest: UUID?
    @Binding var isChecking: Bool
    @ViewBuilder let routePicker: () -> RoutePicker
    @State private var results: [ReachabilitySite: SiteCheckResult] = [:]
    @State private var egress: EgressCheckResult?
    @State private var egressChecking = false
    @State private var localIPv6: LocalIPv6Status = LocalIPv6Inspector.detect()
    @State private var domainInput = ""
    @State private var domainRun: UUID?
    @State private var domainResult: DomainDiagnosticResult?
    @State private var domainError: String?

    var body: some View {
        VStack(spacing: 12) {
            self.egressCard
            VStack(alignment: .leading, spacing: 10) {
                AppSectionHeader(tr("ui.sites.region_title"), symbol: "globe")
                row(.gemini)
                row(.chatGPTRegion)
                row(.claudeRegion)
                SheetNote(text: tr("ui.sites.region_note"))
            }.appSectionCard(padding: 12)
            VStack(alignment: .leading, spacing: 10) {
                routePicker()
                SheetNote(text: tr("ui.sites.note"))
                row(.chatGPT)
                row(.youtube)
                Divider().opacity(0.4)
                self.domainDiagnosticSection
            }.appSectionCard(padding: 12)
        }
        .task(id: runRequest) {
            guard runRequest != nil else { return }
            results = [:]
            egress = nil
            egressChecking = true
            localIPv6 = LocalIPv6Inspector.detect()
            defer {
                egressChecking = false
                isChecking = false
            }
            await withTaskGroup(of: Void.self) { groupTasks in
                groupTasks.addTask { [client, proxyHost] in
                    let result: EgressCheckResult = if let client {
                        await NetworkDiagnosticsProbe.checkEgress(client: client, host: proxyHost)
                    } else {
                        .controllerError
                    }
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        egress = result
                        egressChecking = false
                    }
                }
                for site in ReachabilitySite.allCases {
                    groupTasks.addTask { [group, client, proxyHost] in
                        let outcome: SiteCheckResult = if let client {
                            await site.check(group: group, client: client, proxyHost: proxyHost)
                        } else {
                            .controllerError
                        }
                        await MainActor.run {
                            guard !Task.isCancelled else { return }
                            results[site] = outcome
                        }
                    }
                }
            }
        }
        .task(id: domainRun) {
            guard domainRun != nil else { return }
            guard let client else {
                domainError = tr("ui.sites.controller_error")
                domainRun = nil
                return
            }
            let outcome = await DomainDiagnosticProbe.diagnose(domain: domainInput, group: group, client: client)
            guard !Task.isCancelled else { return }
            if let outcome {
                domainResult = outcome
                domainError = nil
            } else {
                domainResult = nil
                domainError = tr("ui.sites.domain_invalid")
            }
            domainRun = nil
        }
    }

    private var egressCard: some View {
        let dns = appViewModel.nativeDNSSnapshot
        return VStack(alignment: .leading, spacing: 8) {
            AppSectionHeader(tr("ui.sites.egress_title"), symbol: "network")
            HStack(spacing: 6) {
                SemanticTag(text: "IPv6 \(appViewModel.settingsIPv6 ? "ON" : "OFF")",
                            tint: appViewModel.settingsIPv6 ? nativePositive : nativeSecondaryLabel)
                if let dns {
                    SemanticTag(text: "dns.ipv6 \(dns.dnsIPv6 ? "ON" : "OFF")",
                                tint: dns.dnsIPv6 ? nativePositive : nativeWarning)
                    if let mode = dns.enhancedMode {
                        SemanticTag(text: mode, tint: mode == "fake-ip" ? nativeInfo : nativeSecondaryLabel)
                    }
                }
                SemanticTag(text: "TUN \(appViewModel.isTunEnabled ? "ON" : "OFF")",
                            tint: appViewModel.isTunEnabled ? nativeTeal : nativeSecondaryLabel)
            }
            HStack {
                Text(tr("ui.sites.local_ipv6"))
                Spacer()
                switch localIPv6 {
                case let .available(address, isULA):
                    Text(isULA ? tr("ui.sites.local_ipv6_ula", address) : address)
                        .font(.appMono(size: MenuBarLayoutTokens.FontSize.caption))
                        .foregroundStyle(nativePositive)
                        .lineLimit(1).truncationMode(.middle)
                case .unavailable:
                    Text(tr("ui.sites.local_ipv6_none")).foregroundStyle(nativeWarning)
                }
            }
            HStack {
                Text(tr("ui.sites.egress_ipv4"))
                Spacer()
                self.egressIPv4Label
            }
            HStack {
                Text(tr("ui.sites.egress_ipv6"))
                Spacer()
                self.egressIPv6Label
            }
        }.appSectionCard(padding: 12)
    }

    @ViewBuilder
    private var egressIPv4Label: some View {
        if egressChecking && egress == nil {
            ProgressView().controlSize(.small)
        } else {
            switch egress {
            case let .resolved(ipv4, _):
                if let ipv4 {
                    Text(verbatim: ipv4.summary)
                        .font(.appMono(size: MenuBarLayoutTokens.FontSize.caption))
                        .foregroundStyle(nativePositive)
                        .lineLimit(1).truncationMode(.tail)
                        .help(ipv4.summary)
                } else {
                    Text(tr("ui.sites.egress_none")).foregroundStyle(nativeWarning)
                }
            case .proxyUnavailable: Text(tr("ui.sites.proxy_unavailable")).foregroundStyle(nativeWarning)
            case .proxyAuthRequired: Text(tr("ui.sites.proxy_auth")).foregroundStyle(nativeWarning)
            case .controllerError: Text(tr("ui.sites.controller_error")).foregroundStyle(nativeWarning)
            case .failed: Text(tr("ui.sites.unreachable")).foregroundStyle(nativeWarning)
            case nil: Text(tr("ui.sites.not_tested")).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var egressIPv6Label: some View {
        if egressChecking && egress == nil {
            ProgressView().controlSize(.small)
        } else {
            switch egress {
            case let .resolved(_, ipv6):
                if let ipv6 {
                    Text(verbatim: ipv6)
                        .font(.appMono(size: MenuBarLayoutTokens.FontSize.caption))
                        .foregroundStyle(nativePositive)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text(tr("ui.sites.egress_none")).foregroundStyle(.secondary)
                }
            case .proxyUnavailable: Text(tr("ui.sites.proxy_unavailable")).foregroundStyle(nativeWarning)
            case .proxyAuthRequired: Text(tr("ui.sites.proxy_auth")).foregroundStyle(nativeWarning)
            case .controllerError: Text(tr("ui.sites.controller_error")).foregroundStyle(nativeWarning)
            case .failed: Text(tr("ui.sites.unreachable")).foregroundStyle(nativeWarning)
            case nil: Text(tr("ui.sites.not_tested")).foregroundStyle(.secondary)
            }
        }
    }

    private var domainDiagnosticSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("ui.sites.domain_title"))
                .font(.app(size: MenuBarLayoutTokens.FontSize.subheadline, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField(tr("ui.sites.domain_placeholder"), text: $domainInput)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.appMono(size: MenuBarLayoutTokens.FontSize.caption))
                    .onSubmit { triggerDomainCheck() }
                Button(tr("ui.sites.domain_check")) { triggerDomainCheck() }
                    .appBorderedButtonStyle()
                    .controlSize(.small)
                    .disabled(domainInput.trimmed.isEmpty || domainRun != nil)
            }
            if domainRun != nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(tr("ui.sites.domain_checking")).font(.app(size: MenuBarLayoutTokens.FontSize.caption)).foregroundStyle(.secondary)
                }
            }
            if let domainError {
                SheetNote(text: domainError, tint: nativeCritical)
            }
            if let result = domainResult {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(tr("ui.sites.dns_a"))
                        Spacer()
                        if result.dnsFailed {
                            Text(tr("ui.sites.controller_error")).foregroundStyle(nativeWarning)
                        } else if result.aRecords.isEmpty {
                            Text(tr("ui.sites.dns_empty")).foregroundStyle(nativeWarning)
                        } else {
                            let display = result.aRecords.prefix(2).joined(separator: ", ")
                            Text(result.hasFakeIP ? "\(display) (Fake-IP)" : display)
                                .font(.appMono(size: MenuBarLayoutTokens.FontSize.caption))
                                .foregroundStyle(nativePositive)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    HStack {
                        Text(tr("ui.sites.dns_aaaa"))
                        Spacer()
                        if result.dnsFailed {
                            Text(tr("ui.sites.controller_error")).foregroundStyle(nativeWarning)
                        } else if result.aaaaRecords.isEmpty {
                            Text(tr("ui.sites.dns_empty")).foregroundStyle(.secondary)
                        } else {
                            Text(result.aaaaRecords.prefix(2).joined(separator: ", "))
                                .font(.appMono(size: MenuBarLayoutTokens.FontSize.caption))
                                .foregroundStyle(nativePositive)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    HStack {
                        Text(tr("ui.sites.domain_https", result.domain))
                        Spacer()
                        self.resultBadge(result.reachability)
                    }
                }
                .font(.app(size: MenuBarLayoutTokens.FontSize.caption))
            }
        }
    }

    private func triggerDomainCheck() {
        guard !domainInput.trimmed.isEmpty, domainRun == nil else { return }
        domainError = nil
        domainResult = nil
        domainRun = UUID()
    }

    private func row(_ site: ReachabilitySite) -> some View {
        HStack {
            Text(verbatim: site.displayName).help(site.url)
            Spacer()
            if let outcome = results[site] {
                self.resultBadge(outcome)
            } else if runRequest != nil && isChecking {
                ProgressView().controlSize(.small)
            } else {
                Text(tr("ui.sites.not_tested")).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func resultBadge(_ outcome: SiteCheckResult) -> some View {
        switch outcome {
        case let .regionSupported(code): Text(tr("ui.sites.region_supported", code)).foregroundStyle(nativePositive)
        case let .regionRestricted(code): Text(code.map { tr("ui.sites.region_blocked_code", $0) } ?? tr("ui.sites.region_blocked")).foregroundStyle(nativeCritical)
        case .indeterminate: Text(tr("ui.sites.region_unknown")).foregroundStyle(nativeWarning)
        case .proxyUnavailable: Text(tr("ui.sites.proxy_unavailable")).foregroundStyle(nativeWarning)
        case .proxyAuthRequired: Text(tr("ui.sites.proxy_auth")).foregroundStyle(nativeWarning)
        case let .reachable(delay): Text(tr("ui.sites.reachable", delay)).foregroundStyle(nativePositive)
        case .timeout: Text(tr("ui.common.timeout")).foregroundStyle(nativeWarning)
        case .unreachable: Text(tr("ui.sites.unreachable")).foregroundStyle(nativeWarning)
        case .controllerError: Text(tr("ui.sites.controller_error")).foregroundStyle(nativeWarning)
        }
    }
}
