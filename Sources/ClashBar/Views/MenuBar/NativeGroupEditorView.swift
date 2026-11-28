import SwiftUI

struct NativeGroupEditorView: TranslatingView {
    @EnvironmentObject var appViewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    let context: GroupEditorContext
    @State private var members: [String]
    @State private var confirmDelete = false
    @State private var saving = false
    @State private var error: String?

    init(context: GroupEditorContext) {
        self.context = context
        _members = State(initialValue: context.group.members)
    }

    private var availableGroups: [String] {
        context.document.groups.map(\.name).filter { $0 != context.group.name && !members.contains($0) }
    }

    private var availableStaticNodes: [String] {
        context.document.staticNodes.filter { $0 != context.group.name && !members.contains($0) }
    }

    private var availableBuiltIn: [String] {
        NativeProxyProviderDocument.builtInPolicies.filter { !members.contains($0) }
    }

    var body: some View {
        ModalSheetContainer(title: tr("ui.groups.edit"), subtitle: context.group.name + " · " + context.document.configURL.lastPathComponent,
                            symbol: "point.3.connected.trianglepath.dotted") {
            VStack(alignment: .leading, spacing: 12) {
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
                            ForEach(availableGroups, id: \.self) { name in
                                Button(name) { members.append(name) }
                            }
                        }
                    }
                    if !availableStaticNodes.isEmpty {
                        Section(tr("ui.groups.section.nodes")) {
                            ForEach(availableStaticNodes, id: \.self) { name in
                                Button(name) { members.append(name) }
                            }
                        }
                    }
                    if !availableBuiltIn.isEmpty {
                        Section(tr("ui.groups.section.builtin")) {
                            ForEach(availableBuiltIn, id: \.self) { name in
                                Button(name) { members.append(name) }
                            }
                        }
                    }
                }
                .disabled(availableGroups.isEmpty && availableStaticNodes.isEmpty && availableBuiltIn.isEmpty)
                if context.willReload { SheetNote(text: tr("ui.proxy_provider.reload_info")) }
                if context.isSubscription { SheetNote(text: tr("ui.groups.subscription_note")) }
                if let error { SheetNote(text: error, tint: nativeCritical) }
            }.appSectionCard(padding: 12).disabled(saving)
        } footer: {
            HStack {
                Button(tr("ui.groups.delete"), role: .destructive) { confirmDelete = true }
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(tr("ui.action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("ui.proxy_provider.save")) { save(members) }.keyboardShortcut(.defaultAction)
                    .disabled(members == context.group.members)
            }.disabled(saving)
        }
        .interactiveDismissDisabled(saving)
        .alert(tr("ui.groups.delete_confirm", context.group.name), isPresented: $confirmDelete) {
            Button(tr("ui.action.cancel"), role: .cancel) {}
            Button(tr("ui.action.delete"), role: .destructive) { save(nil) }
        }
    }

    private func save(_ newMembers: [String]?) {
        guard !saving else { return }
        saving = true
        error = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                _ = try await appViewModel.saveProxyProvider(.group(name: context.group.name, members: newMembers), document: context.document, fallback: nil)
                dismiss()
            } catch NativeProxyProviderError.emptyGroups { self.error = tr("ui.groups.empty") }
            catch { self.error = appViewModel.proxyProviderErrorText(error) }
        }
    }
}
