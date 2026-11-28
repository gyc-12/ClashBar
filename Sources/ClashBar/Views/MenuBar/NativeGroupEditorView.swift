import SwiftUI

struct NativeGroupEditorView: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    @EnvironmentObject var proxyStore: ProxyStore
    @Environment(\.dismiss) private var dismiss
    let context: GroupEditorContext
    @State private var name: String
    @State private var groupType: String
    @State private var members: [String]
    @State private var boundProviders: [String]
    @State private var includeAllProviders: Bool
    @State private var filterPattern: String
    @State private var excludeFilterPattern: String
    @State private var confirmDelete = false
    @State private var saving = false
    @State private var error: String?

    init(context: GroupEditorContext) {
        self.context = context
        if let group = context.group {
            _name = State(initialValue: group.name)
            _groupType = State(initialValue: group.type)
            _members = State(initialValue: group.members)
            _boundProviders = State(initialValue: group.use)
            _includeAllProviders = State(initialValue: group.includeAllProviders)
            _filterPattern = State(initialValue: group.filter ?? "")
            _excludeFilterPattern = State(initialValue: group.excludeFilter ?? "")
        } else {
            _name = State(initialValue: "")
            _groupType = State(initialValue: "select")
            _members = State(initialValue: [])
            _boundProviders = State(initialValue: [])
            _includeAllProviders = State(initialValue: false)
            _filterPattern = State(initialValue: "")
            _excludeFilterPattern = State(initialValue: "")
        }
    }

    private var isCreating: Bool { context.group == nil }

    private var currentGroupName: String { context.group?.name ?? name.trimmed }

    private var typeChoices: [String] {
        var list = NativeGroupDraft.supportedTypes
        if !list.contains(groupType) { list.append(groupType) }
        return list
    }

    private var availableGroups: [String] {
        context.document.groups.map(\.name).filter { $0 != currentGroupName && !members.contains($0) }
    }

    private var availableStaticNodes: [String] {
        context.document.staticNodes.filter { $0 != currentGroupName && !members.contains($0) }
    }

    private var availableBuiltIn: [String] {
        NativeProxyProviderDocument.builtInPolicies.filter { !members.contains($0) }
    }

    private var hasChanges: Bool {
        if isCreating { return !name.trimmed.isEmpty }
        guard let group = context.group else { return false }
        return groupType != group.type
            || members != group.members
            || boundProviders != group.use
            || includeAllProviders != group.includeAllProviders
            || filterPattern.trimmedNonEmpty != group.filter
            || excludeFilterPattern.trimmedNonEmpty != group.excludeFilter
    }

    private struct RegexPreview {
        let total: Int
        let matched: [String]
        let invalidMessage: String?
    }

    private var regexPreview: RegexPreview {
        let includePattern = filterPattern.trimmedNonEmpty
        let excludePattern = excludeFilterPattern.trimmedNonEmpty
        let includeRegex: NSRegularExpression?
        let excludeRegex: NSRegularExpression?
        do {
            includeRegex = try includePattern.map { try NSRegularExpression(pattern: $0) }
            excludeRegex = try excludePattern.map { try NSRegularExpression(pattern: $0) }
        } catch {
            return RegexPreview(total: 0, matched: [], invalidMessage: tr("ui.groups.invalid_regex"))
        }

        let sourceNames: [String]
        if includeAllProviders {
            sourceNames = context.document.entries.filter(\.enabled).map(\.name)
        } else {
            sourceNames = boundProviders
        }
        var seen = Set<String>()
        var pool: [String] = []
        for providerName in sourceNames {
            for node in proxyStore.proxyProvidersDetail[providerName]?.proxies ?? [] where seen.insert(node.name).inserted {
                pool.append(node.name)
            }
        }
        let filtered = pool.filter { nodeName in
            let range = NSRange(nodeName.startIndex..<nodeName.endIndex, in: nodeName)
            if let includeRegex, includeRegex.firstMatch(in: nodeName, range: range) == nil { return false }
            if let excludeRegex, excludeRegex.firstMatch(in: nodeName, range: range) != nil { return false }
            return true
        }
        return RegexPreview(total: pool.count, matched: filtered, invalidMessage: nil)
    }

    var body: some View {
        let preview = self.regexPreview
        return ModalSheetContainer(
            title: tr(isCreating ? "ui.groups.create" : "ui.groups.edit"),
            subtitle: [context.group?.name, context.document.configURL.lastPathComponent].compactMap { $0 }.joined(separator: " · "),
            symbol: "point.3.connected.trianglepath.dotted",
            height: MenuBarLayoutTokens.Sheet.tallHeight)
        {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    if isCreating {
                        SheetField(title: tr("ui.groups.name")) {
                            TextField(tr("ui.groups.name_placeholder"), text: $name)
                                .labelsHidden().textFieldStyle(.roundedBorder)
                        }
                    }
                    Picker(tr("ui.groups.type"), selection: $groupType) {
                        ForEach(typeChoices, id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                }.appSectionCard(padding: 12)

                VStack(alignment: .leading, spacing: 10) {
                    AppSectionHeader(tr("ui.groups.members_section"), count: "\(members.count)")
                    SheetNote(text: tr("ui.groups.members_note"))
                    ForEach(Array(members.enumerated()), id: \.element) { index, member in
                        HStack(spacing: 6) {
                            Text(verbatim: member).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if members.count > 1 {
                                Button {
                                    members.swapAt(index, index - 1)
                                } label: { Image(systemName: "chevron.up") }
                                .buttonStyle(.borderless).disabled(index == 0)
                                .accessibilityLabel(tr("ui.groups.move_up", member))
                                Button {
                                    members.swapAt(index, index + 1)
                                } label: { Image(systemName: "chevron.down") }
                                .buttonStyle(.borderless).disabled(index == members.count - 1)
                                .accessibilityLabel(tr("ui.groups.move_down", member))
                            }
                            Button { members.removeAll { $0 == member } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(tr("ui.groups.remove", member))
                        }
                    }
                    Menu(tr("ui.groups.add_member")) {
                        if !availableGroups.isEmpty {
                            Section(tr("ui.groups.section.groups")) {
                                ForEach(availableGroups, id: \.self) { choice in
                                    Button(choice) { members.append(choice) }
                                }
                            }
                        }
                        if !availableStaticNodes.isEmpty {
                            Section(tr("ui.groups.section.nodes")) {
                                ForEach(availableStaticNodes, id: \.self) { choice in
                                    Button(choice) { members.append(choice) }
                                }
                            }
                        }
                        if !availableBuiltIn.isEmpty {
                            Section(tr("ui.groups.section.builtin")) {
                                ForEach(availableBuiltIn, id: \.self) { choice in
                                    Button(choice) { members.append(choice) }
                                }
                            }
                        }
                    }
                    .disabled(availableGroups.isEmpty && availableStaticNodes.isEmpty && availableBuiltIn.isEmpty)
                }.appSectionCard(padding: 12)

                VStack(alignment: .leading, spacing: 10) {
                    AppSectionHeader(tr("ui.groups.providers_section"))
                    Toggle(tr("ui.groups.include_all_providers"), isOn: $includeAllProviders)
                    if !includeAllProviders {
                        if context.document.entries.isEmpty {
                            SheetNote(text: tr("ui.empty.proxy_providers"))
                        } else {
                            ForEach(context.document.entries) { entry in
                                Toggle(isOn: Binding(
                                    get: { boundProviders.contains(entry.name) },
                                    set: { selected in
                                        if selected {
                                            if !boundProviders.contains(entry.name) { boundProviders.append(entry.name) }
                                        } else {
                                            boundProviders.removeAll { $0 == entry.name }
                                        }
                                    }))
                                {
                                    HStack(spacing: 6) {
                                        Text(verbatim: entry.name)
                                        if !entry.enabled {
                                            SemanticTag(text: tr("ui.proxy_provider.disabled"), tint: nativeSecondaryLabel, monospaced: false)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    SheetField(title: tr("ui.groups.filter")) {
                        TextField("(?i)US|美国", text: $filterPattern)
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            .font(.appMono(size: MenuBarLayoutTokens.FontSize.caption))
                    }
                    SheetField(title: tr("ui.groups.exclude_filter")) {
                        TextField("(?i)剩余|到期|官网", text: $excludeFilterPattern)
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            .font(.appMono(size: MenuBarLayoutTokens.FontSize.caption))
                    }
                    if let invalid = preview.invalidMessage {
                        SheetNote(text: invalid, tint: nativeCritical, symbol: "exclamationmark.triangle")
                    } else if preview.total > 0 {
                        let sample = preview.matched.prefix(4).joined(separator: ", ")
                        let suffix = preview.matched.count > 4 ? "…" : ""
                        let summary = preview.matched.isEmpty
                            ? tr("ui.groups.filter_preview_none", preview.total)
                            : tr("ui.groups.filter_preview", preview.matched.count, preview.total, sample + suffix)
                        SheetNote(text: summary, tint: preview.matched.isEmpty ? nativeWarning : nativeSecondaryLabel)
                    } else if includeAllProviders || !boundProviders.isEmpty {
                        SheetNote(text: tr("ui.groups.filter_preview_unloaded"))
                    }
                }.appSectionCard(padding: 12)

                if context.willReload || context.isSubscription {
                    VStack(alignment: .leading, spacing: 8) {
                        if context.willReload { SheetNote(text: tr("ui.proxy_provider.reload_info")) }
                        if context.isSubscription { SheetNote(text: tr("ui.groups.subscription_note")) }
                    }.appSectionCard(padding: 12)
                }
                if let error { SheetNote(text: error, tint: nativeCritical, symbol: "exclamationmark.triangle") }
            }.disabled(saving)
        } footer: {
            HStack {
                if !isCreating {
                    Button(tr("ui.groups.delete"), role: .destructive) { confirmDelete = true }
                }
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(tr("ui.action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("ui.proxy_provider.save")) { saveDraft() }.keyboardShortcut(.defaultAction)
                    .disabled(!hasChanges || preview.invalidMessage != nil)
            }.disabled(saving)
        }
        .interactiveDismissDisabled(saving)
        .alert(tr("ui.groups.delete_confirm", context.group?.name ?? ""), isPresented: $confirmDelete) {
            Button(tr("ui.action.cancel"), role: .cancel) {}
            Button(tr("ui.action.delete"), role: .destructive) { deleteGroup() }
        }
    }

    private func saveDraft() {
        guard !saving else { return }
        saving = true
        error = nil
        let targetName = isCreating ? name : (context.group?.name ?? "")
        let draft = NativeGroupDraft(
            type: groupType,
            members: members,
            use: includeAllProviders ? [] : boundProviders,
            includeAllProviders: includeAllProviders,
            filter: filterPattern.trimmedNonEmpty,
            excludeFilter: excludeFilterPattern.trimmedNonEmpty,
            defaultTestURL: appViewModel.defaultHealthcheckURL)
        Task { @MainActor in
            defer { saving = false }
            do {
                _ = try await appViewModel.saveProxyProvider(
                    .configureGroup(name: targetName, draft: draft, create: isCreating),
                    document: context.document,
                    fallback: nil)
                dismiss()
            } catch NativeProxyProviderError.emptyGroups { self.error = tr("ui.groups.empty") }
            catch { self.error = appViewModel.proxyProviderErrorText(error) }
        }
    }

    private func deleteGroup() {
        guard !saving, let group = context.group else { return }
        saving = true
        error = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                _ = try await appViewModel.saveProxyProvider(.group(name: group.name, members: nil), document: context.document, fallback: nil)
                dismiss()
            } catch NativeProxyProviderError.emptyGroups { self.error = tr("ui.groups.empty") }
            catch { self.error = appViewModel.proxyProviderErrorText(error) }
        }
    }
}
