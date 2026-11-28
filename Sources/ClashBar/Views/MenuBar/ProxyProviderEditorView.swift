import SwiftUI

struct ProxyProviderEditorView: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    let context: ProxyProviderEditorContext
    @State private var name: String
    @State private var url: String
    @State private var interval: String
    @State private var healthURL: String
    @State private var healthInterval: String
    @State private var options: SubscriptionOptions
    @State private var userAgents: String
    @State private var bindings: Set<String> = []
    @State private var showOptions = false
    @State private var saving = false
    @State private var error: String?
    @State private var fallback: NativeProxyProviderService.Fallback?
    @State private var needsFallback = false

    init(context: ProxyProviderEditorContext) {
        self.context = context
        if context.operation == .edit, let entry = context.entry {
            self._name = State(initialValue: entry.name)
            self._url = State(initialValue: entry.url ?? "")
            self._interval = State(initialValue: entry.interval.map(String.init) ?? "")
            self._healthURL = State(initialValue: entry.healthCheckURL ?? "")
            self._healthInterval = State(initialValue: String(entry.options.healthInterval))
            self._options = State(initialValue: entry.options)
            self._userAgents = State(initialValue: entry.options.userAgents.joined(separator: "\n"))
        } else {
            let defaults = SubscriptionOptions()
            self._name = State(initialValue: "")
            self._url = State(initialValue: "")
            self._interval = State(initialValue: String(SubscriptionOptions.defaultInterval))
            self._healthURL = State(initialValue: SubscriptionOptions.defaultHealthURL)
            self._healthInterval = State(initialValue: String(defaults.healthInterval))
            self._options = State(initialValue: defaults)
            self._userAgents = State(initialValue: defaults.userAgents.joined(separator: "\n"))
        }
    }

    private var title: String {
        switch context.operation {
        case .add: tr("ui.proxy_provider.add")
        case .edit: tr("ui.proxy_provider.edit")
        case .enable: tr("ui.proxy_provider.enable")
        case .disable: tr("ui.proxy_provider.disable")
        case .delete: tr("ui.proxy_provider.delete")
        }
    }

    private var isHTTPSubscription: Bool {
        context.operation == .add || context.entry?.type == "http"
    }

    private var automaticGroups: [String] {
        context.document.groups.filter(\.automatic).map(\.name)
    }

    private var previewGroups: [String] {
        if let entry = context.entry { return context.document.affectedGroups(for: entry.name) }
        return automaticGroups + context.document.groups.filter { bindings.contains($0.name) }.map(\.name)
    }

    private var downloadRouteChoices: [String] {
        var choices = ["DIRECT"] + context.document.groups.map(\.name) + context.document.staticNodes
        if !choices.contains(options.downloadProxy) { choices.append(options.downloadProxy) }
        return choices
    }

    private var sheetHeight: CGFloat {
        if (context.operation == .add || (context.operation == .edit && isHTTPSubscription)) && showOptions { return 600 }
        if context.operation == .add || context.operation == .edit { return 460 }
        return needsFallback ? 520 : 440
    }

    var body: some View {
        ModalSheetContainer(title: title,
                            subtitle: [context.document.configURL.lastPathComponent, context.entry?.name].compactMap { $0 }.joined(separator: " · "),
                            symbol: "externaldrive.fill", height: self.sheetHeight) {
            VStack(alignment: .leading, spacing: 12) {
                if context.operation == .add || context.operation == .edit {
                    VStack(alignment: .leading, spacing: 12) {
                        field("ui.proxy_provider.name", text: $name)
                        if isHTTPSubscription {
                            field("ui.proxy_provider.url", text: $url, prompt: "https://…", monospaced: true)
                        }
                    }.appSectionCard(padding: 12)
                }
                if context.operation == .add || (context.operation == .edit && isHTTPSubscription) {
                    DisclosureGroup(tr("ui.proxy_provider.options"), isExpanded: $showOptions) {
                        VStack(alignment: .leading, spacing: 10) {
                            field("ui.proxy_provider.interval", text: $interval, monospaced: true)
                            Toggle(tr("ui.subscription.health_enabled"), isOn: $options.healthEnabled)
                            field("ui.proxy_provider.healthcheck", text: $healthURL, prompt: SubscriptionOptions.defaultHealthURL, monospaced: true)
                            field("ui.subscription.health_interval", text: $healthInterval, monospaced: true)
                            Picker(tr("ui.subscription.route"), selection: $options.downloadProxy) {
                                ForEach(downloadRouteChoices, id: \.self) { Text(verbatim: $0).tag($0) }
                            }
                            SheetNote(text: tr("ui.subscription.route_note"))
                            field("ui.subscription.prefix", text: $options.prefix, prompt: tr("ui.subscription.prefix_placeholder"))
                            SheetField(title: tr("ui.subscription.agents")) {
                                TextEditor(text: $userAgents).font(.system(.caption, design: .monospaced)).frame(height: 78)
                            }
                            if context.operation == .add {
                                let manual = context.document.groups.filter { !$0.automatic }
                                if !manual.isEmpty {
                                    Text(tr("ui.proxy_provider.bind")).font(.app(size: MenuBarLayoutTokens.FontSize.subheadline)).foregroundStyle(.secondary)
                                    ForEach(manual) { group in
                                        Toggle(group.name, isOn: Binding(get: { bindings.contains(group.name) }, set: { selected in
                                            if selected { bindings.insert(group.name) } else { bindings.remove(group.name) }
                                        }))
                                    }
                                }
                            }
                        }.padding(.top, 10)
                    }.appSectionCard(padding: 12)
                }
                VStack(alignment: .leading, spacing: 10) {
                    if context.operation == .delete { note("ui.proxy_provider.delete_info") }
                    if !previewGroups.isEmpty && (context.entry?.enabled != false || context.operation == .enable) {
                        SheetNote(text: tr("ui.proxy_provider.groups", previewGroups.joined(separator: ", ")))
                    }
                    if context.willReload { note("ui.proxy_provider.reload_info") }
                    if context.isSubscription {
                        SheetNote(text: tr("ui.proxy_provider.subscription_info"), tint: self.nativeWarning, symbol: "exclamationmark.triangle")
                    }
                }.appSectionCard(padding: 12)
                if let error { SheetNote(text: error, tint: self.nativeCritical, symbol: "exclamationmark.triangle") }
                if needsFallback {
                    SheetField(title: tr("ui.proxy_provider.fallback")) {
                        Picker(tr("ui.proxy_provider.fallback"), selection: $fallback) {
                            Text(tr("ui.proxy_provider.fallback_required")).tag(nil as NativeProxyProviderService.Fallback?).disabled(true)
                            ForEach(NativeProxyProviderService.Fallback.allCases) { value in
                                Text(tr("ui.proxy_provider.fallback.\(value.rawValue)")).tag(Optional(value))
                            }
                        }.labelsHidden()
                    }.appSectionCard(padding: 12)
                }
            }
            .disabled(saving)
        } footer: {
            HStack(spacing: 8) {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button(tr("ui.action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                    .appBorderedButtonStyle().disabled(saving)
                Button(context.operation == .delete ? tr("ui.action.delete") : tr("ui.proxy_provider.save"),
                       role: context.operation == .delete ? .destructive : nil) { save() }
                    .keyboardShortcut(.defaultAction).appBorderedButtonStyle(prominent: true)
                    .tint(context.operation == .delete ? self.nativeCritical : self.nativeAccent)
                    .disabled(saving || (needsFallback && fallback == nil))
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func note(_ key: String) -> some View { SheetNote(text: tr(key)) }

    private func field(_ key: String, text: Binding<String>, prompt: String? = nil, monospaced: Bool = false) -> some View {
        SheetField(title: tr(key)) {
            TextField(tr(key), text: text, prompt: prompt.map { Text($0) })
                .labelsHidden().textFieldStyle(.roundedBorder)
                .font(monospaced ? .appMono(size: MenuBarLayoutTokens.FontSize.callout) : .app(size: MenuBarLayoutTokens.FontSize.body))
        }
    }

    private func parsedOptions() throws -> (interval: Int?, options: SubscriptionOptions) {
        let raw = interval.trimmingCharacters(in: .whitespacesAndNewlines)
        let seconds = Int(raw)
        guard raw.isEmpty || seconds != nil else { throw NativeProxyProviderError.invalidInterval }
        let healthSeconds = healthInterval.trimmedNonEmpty ?? String(SubscriptionOptions.defaultHealthInterval)
        guard let parsed = Int(healthSeconds) else { throw NativeProxyProviderError.invalidInterval }
        var draft = options
        draft.healthInterval = parsed
        draft.userAgents = userAgents.components(separatedBy: .newlines).compactMap(\.trimmedNonEmpty)
        return (seconds, draft)
    }

    private func action() throws -> NativeProxyProviderAction {
        if context.operation == .add {
            let parsed = try parsedOptions()
            return .add(name: name, url: url, interval: parsed.interval, healthCheckURL: healthURL.trimmedNonEmpty,
                        groups: bindings, options: parsed.options)
        }
        guard let entry = context.entry else { throw NativeProxyProviderError.conflict }
        switch context.operation {
        case .edit:
            if entry.type == "http" {
                let parsed = try parsedOptions()
                return .edit(name: entry.name, newName: name, url: url, interval: parsed.interval,
                             healthCheckURL: healthURL.trimmedNonEmpty, options: parsed.options)
            }
            return .edit(name: entry.name, newName: name, url: entry.url ?? "")
        case .enable: return .setEnabled(name: entry.name, enabled: true)
        case .disable: return .setEnabled(name: entry.name, enabled: false)
        case .delete: return .delete(name: entry.name)
        case .add: throw NativeProxyProviderError.conflict
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        error = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                _ = try await appViewModel.saveProxyProvider(action(), document: context.document, fallback: fallback)
                dismiss()
            } catch let failure as NativeProxyProviderError {
                if case .emptyGroups = failure { needsFallback = true }
                error = appViewModel.proxyProviderErrorText(failure)
            } catch {
                self.error = appViewModel.proxyProviderErrorText(error)
            }
        }
    }
}
