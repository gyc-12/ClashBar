import Foundation

struct NativeRuleSaveResult {
    let backupURL: URL?
    let applied: Bool
}

@MainActor
extension AppViewModel {
    var nativeRuleService: NativeRuleService {
        NativeRuleService(homeDirectory: self.workingDirectoryManager.rootDirectoryURL)
    }

    var displayedRuleItems: [RuleItem] {
        if self.isRemoteTarget { return self.ruleItems }
        guard let document = self.nativeRuleDocument else { return [] }
        guard self.nativeRulesMatchRuntime else { return document.entries.map(\.item) }
        return zip(document.entries, self.ruleItems).map { entry, runtime in
            let item = entry.item
            return RuleItem(type: item.type, payload: item.payload, proxy: item.proxy,
                            index: runtime.index, nativeEntry: entry, statistics: runtime.statistics)
        }
    }

    var nativeRulesMatchRuntime: Bool {
        guard !self.isRemoteTarget, self.processManager.isRunning, let document = self.nativeRuleDocument else {
            return false
        }
        return self.isActiveRuleDocument(document) && document.matchesRuntime(self.ruleItems)
    }

    func isSelectedRoutingConfig(_ config: URL) -> Bool {
        self.configService.selectedConfig?.standardizedFileURL.resolvingSymlinksInPath()
            == config.standardizedFileURL.resolvingSymlinksInPath()
    }

    func isActiveRuleDocument(_ document: NativeRuleDocument) -> Bool {
        guard let path = self.defaults.string(forKey: self.lastSuccessfulConfigPathKey) else { return false }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            == document.configURL.resolvingSymlinksInPath().standardizedFileURL
    }

    func refreshNativeRuleDocument() {
        self.refreshNativeProxyProviderDocument()
        guard !self.isRemoteTarget, let url = self.configService.selectedConfig else {
            self.nativeRuleDocument = nil
            self.nativeRuleDocumentError = nil
            self.nativeDNSSnapshot = nil
            return
        }
        self.nativeDNSSnapshot = try? NativeDNSSettingsService().read(configURL: url)
        do {
            self.nativeRuleDocument = try self.nativeRuleService.read(configURL: url)
            self.nativeRuleDocumentError = nil
        } catch {
            self.nativeRuleDocument = nil
            self.nativeRuleDocumentError = self.quickRuleErrorText(error)
        }
    }

    func applyNativeDNSIPv6(_ enabled: Bool) async {
        guard !self.isRemoteTarget, !self.isQuickRuleSaving, !self.isCoreSettingSyncing, !self.isTunSyncing,
              let url = self.configService.selectedConfig else { return }
        self.refreshNativeRuleDocument()
        guard let snapshot = self.nativeDNSSnapshot, snapshot.dnsIPv6 != enabled else { return }
        self.isQuickRuleSaving = true
        self.isNativeDNSSaving = true
        self.settingsErrorMessage = nil
        self.settingsSavedMessage = nil
        defer {
            self.isNativeDNSSaving = false
            self.isQuickRuleSaving = false
            self.refreshNativeRuleDocument()
        }
        do {
            let edit = try NativeDNSSettingsService().prepareDNSIPv6(enabled, snapshot: snapshot)
            guard edit.hasChanges else { return }
            let running = self.processManager.isRunning
            let activePath = self.appliedProviderConfig?.url ?? self.defaults.string(forKey: self.lastSuccessfulConfigPathKey)
                .map { self.canonicalProviderPath(URL(fileURLWithPath: $0)) }
            let activeFile = running && activePath == self.canonicalProviderPath(url)
            let client: (any MihomoAPITransporting)? = activeFile ? try self.clientOrThrow() : nil
            var updatedPayload = ""
            var previousPayload = ""
            _ = try await self.quickRuleService.commit(
                edit,
                validate: { path in
                    try await self.processManager.validateConfig(configPath: path)
                    guard !self.isRemoteTarget, self.isSelectedRoutingConfig(url) else {
                        throw QuickRuleError.contextChanged
                    }
                    if let client {
                        let latest: [String: JSONValue] = try await client.request(.getConfigs)
                        updatedPayload = try self.quickRuleService.reloadPayload(edit.updatedData, runtime: latest)
                        previousPayload = try self.quickRuleService.reloadPayload(edit.originalConfig, runtime: latest)
                    }
                },
                didWrite: { self.acknowledgeQuickRuleConfigWrite(url) },
                apply: {
                    guard let client else { return }
                    try await client.requestNoResponse(.putConfigs(force: false, path: "", payload: updatedPayload))
                },
                restoreRuntime: {
                    guard let client else { return }
                    try await client.requestNoResponse(.putConfigs(force: false, path: "", payload: previousPayload))
                })
            if activeFile { self.updateAppliedProviderConfig(after: edit) }
            self.settingsSavedMessage = self.tr(activeFile ? "ui.settings.dns_ipv6_applied" : "ui.settings.dns_ipv6_saved_file")
            self.scheduleSettingsFeedbackAutoClearIfNeeded(message: self.settingsSavedMessage ?? "")
        } catch {
            self.settingsErrorMessage = self.quickRuleErrorText(error)
        }
    }

    func openNativeRuleEditor(_ entry: NativeRuleEntry) {
        guard self.canEditQuickRules, let document = self.nativeRuleDocument else { return }
        self.nativeRuleEditorContext = NativeRuleEditorContext(
            document: document, entry: entry,
            isSubscription: self.remoteConfigSubscriptions[document.configURL.lastPathComponent] != nil)
    }

    func saveNativeRule(document: NativeRuleDocument, entry: NativeRuleEntry, raw: String, isCustom: Bool) async throws
        -> NativeRuleSaveResult
    {
        guard self.canEditQuickRules, !self.isCoreSettingSyncing, !self.isTunSyncing,
            self.isSelectedRoutingConfig(document.configURL)
        else { throw QuickRuleError.contextChanged }
        self.isQuickRuleSaving = true
        self.nativeRuleSavingIndex = entry.index
        defer {
            self.isQuickRuleSaving = false
            self.nativeRuleSavingIndex = nil
            self.refreshNativeRuleDocument()
        }
        let edit = try self.nativeRuleService.prepare(document: document, entry: entry, raw: raw, isCustom: isCustom)
        let result = try await self.commitRoutingRuleEdit(edit, document: document, changesRouting: raw != entry.raw)
        self.nativeRuleSaveNotice = self.tr(result.applied ? "ui.native_rule.saved" : "ui.native_rule.saved_file")
        return result
    }

    /// Serialised by isQuickRuleSaving. Verify runtime correspondence before applying a file.
    func commitRoutingRuleEdit(_ edit: NativeRuleEdit, document: NativeRuleDocument, changesRouting: Bool = true,
                              settingsFromFile: Set<String> = [], requireProcessLookup: Bool = false)
        async throws -> NativeRuleSaveResult
    {
        self.ensureAPIClient()
        let running = self.processManager.isRunning
        var runtime: [String: JSONValue] = [:]
        var client: (any MihomoAPITransporting)?
        if running, self.isActiveRuleDocument(document) {
            let candidate = try self.clientOrThrow()
            let rules: RulesSummary = try await candidate.request(.rules)
            if document.matchesRuntime(rules.rules) {
                client = candidate
                runtime = try await candidate.request(.getConfigs)
            }
        }
        var updatedPayload = try self.quickRuleService.reloadPayload(
            edit.provider == nil ? edit.updatedData : edit.originalConfig, runtime: runtime, settingsFromFile: settingsFromFile)
        var previousPayload = try self.quickRuleService.reloadPayload(edit.originalConfig, runtime: runtime)
        func checkProcessLookup(_ values: [String: JSONValue]) throws {
            if requireProcessLookup {
                let mode = try ApplicationRuleService.processMode(in: edit.updatedData,
                    runtime: values.filter { !settingsFromFile.contains($0.key) })
                guard mode != "off" else { throw ApplicationRoutingError.processLookupDisabled }
            }
        }
        try checkProcessLookup(client == nil ? [:] : runtime)
        let reloadClient = changesRouting ? client : nil
        let backup = try await self.quickRuleService.commit(
            edit,
            validate: { path in
                try await self.processManager.validateConfig(configPath: path)
                guard !self.isRemoteTarget, self.isSelectedRoutingConfig(document.configURL) else {
                    throw QuickRuleError.contextChanged
                }
                if let reloadClient {
                    let current: RulesSummary = try await reloadClient.request(.rules)
                    guard document.matchesRuntime(current.rules) else { throw QuickRuleError.contextChanged }
                    let latest: [String: JSONValue] = try await reloadClient.request(.getConfigs)
                    try checkProcessLookup(latest)
                    updatedPayload = try self.quickRuleService.reloadPayload(
                        edit.provider == nil ? edit.updatedData : edit.originalConfig, runtime: latest,
                        settingsFromFile: settingsFromFile)
                    previousPayload = try self.quickRuleService.reloadPayload(edit.originalConfig, runtime: latest)
                }
            },
            didWrite: {
                if edit.provider == nil { self.acknowledgeQuickRuleConfigWrite(document.configURL) }
            },
            apply: {
                guard let reloadClient else { return }
                if let provider = edit.provider {
                    try await reloadClient.requestNoResponse(.updateRuleProvider(name: provider.name))
                } else {
                    try await reloadClient.requestNoResponse(
                        .putConfigs(force: false, path: "", payload: updatedPayload))
                }
            },
            restoreRuntime: {
                guard let reloadClient else { return }
                if let provider = edit.provider {
                    try await reloadClient.requestNoResponse(.updateRuleProvider(name: provider.name))
                } else {
                    try await reloadClient.requestNoResponse(
                        .putConfigs(force: false, path: "", payload: previousPayload))
                }
            })
        if client != nil, edit.provider == nil { self.updateAppliedProviderConfig(after: edit) }
        self.lastRuleSaveApplied = client != nil
        if client != nil { await self.refreshProvidersAndRules() }
        return NativeRuleSaveResult(backupURL: backup, applied: client != nil)
    }
}
