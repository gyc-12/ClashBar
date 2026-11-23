import Foundation

@MainActor
extension AppViewModel {
    var canEditApplicationRules: Bool { self.canEditQuickRules && !self.isOpeningApplicationRules }

    func applicationRuleContext(selected: ApplicationRoutingCandidate? = nil) async throws -> ApplicationRuleEditorContext {
        guard self.canEditApplicationRules, let config = self.configService.selectedConfig,
            !self.isCoreSettingSyncing, !self.isTunSyncing else { throw QuickRuleError.contextChanged }
        self.isOpeningApplicationRules = true
        defer { self.isOpeningApplicationRules = false }
        let document = try self.nativeRuleService.read(configURL: config)
        var runtime: [String: JSONValue] = [:]
        if self.processManager.isRunning, self.isActiveRuleDocument(document) {
            self.ensureAPIClient()
            runtime = try await self.clientOrThrow().request(.getConfigs)
        }
        guard !self.isRemoteTarget, self.isSelectedRoutingConfig(config),
            !self.isCoreActionProcessing, !self.isCoreSettingSyncing, !self.isTunSyncing else {
            throw QuickRuleError.contextChanged
        }
        return ApplicationRuleEditorContext(document: document, selected: selected,
            observed: ApplicationRoutingCandidate.observed(in: self.connectionsStore.connections),
            processMode: try ApplicationRuleService.processMode(in: document.originalData, runtime: runtime),
            fileProcessMode: try ApplicationRuleService.processMode(in: document.originalData),
            isSubscription: self.remoteConfigSubscriptions[config.lastPathComponent] != nil)
    }

    func openApplicationRuleEditor(selected: ApplicationRoutingCandidate? = nil) async {
        do { self.applicationRuleEditorContext = try await self.applicationRuleContext(selected: selected) }
        catch {
            self.runModalAlert(style: .warning, message: self.tr("ui.app_rule.title"),
                informative: self.quickRuleErrorText(error), buttons: [self.tr("ui.action.ok")])
        }
    }

    func saveApplicationRule(_ rule: QuickRoutingRule, context: ApplicationRuleEditorContext,
                             enableProcessLookup: Bool) async throws -> NativeRuleSaveResult {
        guard self.canEditQuickRules, self.isSelectedRoutingConfig(context.document.configURL),
            !self.isCoreSettingSyncing, !self.isTunSyncing else { throw QuickRuleError.contextChanged }
        self.isQuickRuleSaving = true
        defer { self.isQuickRuleSaving = false; self.refreshNativeRuleDocument() }
        let edit = try ApplicationRuleService(homeDirectory: self.workingDirectoryManager.rootDirectoryURL)
            .prepare(rule: rule, document: context.document, enableProcessLookup: enableProcessLookup)
        let result = try await self.commitRoutingRuleEdit(edit, document: context.document,
            settingsFromFile: enableProcessLookup ? ["find-process-mode"] : [], requireProcessLookup: true)
        self.nativeRuleSaveNotice = self.tr(result.applied ? "ui.native_rule.saved" : "ui.native_rule.saved_file")
        self.appendLog(level: "info", message: self.tr("ui.quick_rule.saved_log", rule.target, edit.targetURL.lastPathComponent))
        return result
    }
}
