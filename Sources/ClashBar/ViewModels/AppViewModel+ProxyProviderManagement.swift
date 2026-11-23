import Foundation

struct ProxyProviderEditorContext: Identifiable {
    enum Operation { case add, edit, enable, disable, delete }
    let id = UUID()
    let document: NativeProxyProviderDocument
    let operation: Operation
    let entry: NativeProxyProvider?
    let isSubscription: Bool
    let willReload: Bool
}

struct AppliedProviderConfig {
    let url: URL
    let data: Data
    let status: CoreLifecycleStatus
}

@MainActor
extension AppViewModel {
    var canManageProxyProviders: Bool {
        !self.isRemoteTarget && self.configService.selectedConfig != nil
    }

    var canStartProxyProviderEdit: Bool {
        self.canManageProxyProviders && !self.isCoreActionProcessing && !self.isCoreSettingSyncing && !self.isTunSyncing
            && !self.modeSwitchInFlight && self.providerUpdating.isEmpty
    }

    var nativeProvidersMatchRunningConfig: Bool {
        guard !self.isRemoteTarget, let document = self.nativeProxyProviderDocument, let applied = self.appliedProviderConfig,
              self.processManager.isRunning, applied.status == self.processManager.status else { return false }
        return self.canonicalProviderPath(document.configURL) == applied.url && document.data == applied.data
    }

    func canonicalProviderPath(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    func rememberAppliedProviderConfig(url: URL, data: Data?) {
        self.appliedProviderConfig = data.map {
            AppliedProviderConfig(url: self.canonicalProviderPath(url), data: $0, status: self.processManager.status)
        }
    }

    func updateAppliedProviderConfig(after edit: NativeRuleEdit) {
        guard let baseline = self.appliedProviderConfig, self.processManager.isRunning,
              baseline.status == self.processManager.status, self.canonicalProviderPath(edit.configURL) == baseline.url,
              baseline.data == edit.originalConfig else { return }
        self.rememberAppliedProviderConfig(url: edit.configURL, data: edit.updatedData)
    }

    func refreshNativeProxyProviderDocument() {
        guard self.canManageProxyProviders, let url = self.configService.selectedConfig else {
            self.nativeProxyProviderDocument = nil
            self.nativeProxyProviderError = nil
            self.nativeProxyProviderNotice = nil
            return
        }
        if let old = self.nativeProxyProviderDocument, self.canonicalProviderPath(old.configURL) != self.canonicalProviderPath(url) {
            self.nativeProxyProviderNotice = nil
        }
        do {
            let document = try NativeProxyProviderService().read(configURL: url)
            if document != self.nativeProxyProviderDocument { self.nativeProxyProviderDocument = document }
            self.nativeProxyProviderError = nil
        } catch {
            self.nativeProxyProviderDocument = nil
            self.nativeProxyProviderError = self.proxyProviderErrorText(error)
        }
    }

    func openProxyProviderEditor(_ operation: ProxyProviderEditorContext.Operation, name: String? = nil) {
        guard self.canStartProxyProviderEdit else { return }
        self.nativeProxyProviderNotice = nil
        self.refreshNativeProxyProviderDocument()
        guard let document = self.nativeProxyProviderDocument else { return }
        let entry = name.flatMap { target in document.entries.first { $0.name == target } }
        guard operation == .add || entry != nil else { return }
        let changesRuntime = entry?.enabled != false || operation == .enable
        self.proxyProviderEditorContext = ProxyProviderEditorContext(
            document: document, operation: operation, entry: entry,
            isSubscription: self.remoteConfigSubscriptions[document.configURL.lastPathComponent] != nil,
            willReload: changesRuntime && self.nativeProvidersMatchRunningConfig)
    }

    func saveProxyProvider(_ action: NativeProxyProviderAction, document: NativeProxyProviderDocument,
                           fallback: NativeProxyProviderService.Fallback?) async throws -> Bool {
        guard self.canStartProxyProviderEdit, self.isSelectedRoutingConfig(document.configURL) else { throw QuickRuleError.contextChanged }
        self.isQuickRuleSaving = true  // Existing config/lifecycle write lock shared with native rule edits.
        self.isProxyProviderSaving = true
        self.proxyProviderPresentationGeneration &+= 1
        let refresh = self.providerRefreshTask
        self.cancelProviderRefresh(reason: "superseded")
        defer {
            self.proxyProviderPresentationGeneration &+= 1
            self.isProxyProviderSaving = false
            self.isQuickRuleSaving = false
            self.refreshNativeRuleDocument()
            if self.processManager.isRunning, !self.isRemoteTarget {
                Task { await self.refreshProxyGroups() }
            }
        }
        await refresh?.value
        let service = NativeProxyProviderService()
        let cacheID = UUID()
        var candidate = try service.prepare(action, in: document, fallback: fallback, cacheID: cacheID)
        guard candidate.file.hasChanges else { return self.nativeProvidersMatchRunningConfig }
        try candidate.file.checkUnchanged()
        let status = self.processManager.status
        let activePath = self.appliedProviderConfig?.url ?? self.defaults.string(forKey: self.lastSuccessfulConfigPathKey)
            .map { self.canonicalProviderPath(URL(fileURLWithPath: $0)) }
        let activeFile = self.processManager.isRunning && activePath == self.canonicalProviderPath(document.configURL)
        if activeFile && (self.appliedProviderConfig?.data != document.data || self.appliedProviderConfig?.status != status) {
            throw QuickRuleError.contextChanged
        }
        let shouldApply = activeFile && candidate.changesRuntime
        let needsProbe = candidate.probeProvider != nil || (candidate.changesRuntime && !candidate.affectedGroups.isEmpty)
        let localHome = MihomoProcessManager.resolveWorkingDirectoryURL(configPath: document.configURL.path)
        var inspected: ProxyProviderProbeResult?
        if needsProbe {
            guard let binary = self.processManager.detectedBinaryPath else { throw NativeProxyProviderError.unavailable }
            let probe = ProxyProviderProbe(binary: binary, home: localHome)
            do { inspected = try await probe.inspect(candidate) }
            catch is CancellationError { throw CancellationError() }
            catch { throw NativeProxyProviderError.sourceFailed }
            var empty = Self.emptyAffectedGroups(candidate, in: inspected?.groups ?? [:])
            if !empty.isEmpty {
                // Leave groups already falling back before this edit alone.
                let before: [String: ProxyGroup]
                if shouldApply, let response: ProxyGroupsResponse = try? await self.clientOrThrow().request(.proxies) {
                    before = response.proxies
                } else {
                    let oldEdit = NativeProxyProviderEdit(file: NativeRuleEdit(configURL: document.configURL,
                        originalConfig: document.data, targetURL: document.configURL, originalData: document.data,
                        updatedData: document.data, provider: nil), document: document, affectedGroups: candidate.affectedGroups,
                        probeProvider: nil, freshSource: false, changesRuntime: false)
                    before = (try? await probe.inspect(oldEdit))?.groups ?? [:]
                }
                empty.subtract(Self.emptyAffectedGroups(candidate, in: before))
            }
            if !empty.isEmpty {
                guard let fallback else { throw NativeProxyProviderError.emptyGroups(empty.sorted()) }
                candidate = try service.prepare(action, in: document, fallback: fallback, filteredEmptyGroups: empty, cacheID: cacheID)
            }
        }

        let transaction = self.quickRuleService
        let client = shouldApply ? try self.clientOrThrow() : nil
        var nextPayload = ""
        var previousPayload = ""
        var didAttemptReload = false
        var rollbackVerified = false
        var allowedEmptyGroups = Set<String>()
        if let inspected { allowedEmptyGroups = Self.emptyAffectedGroups(candidate, in: inspected.groups) }
        let editedProvider = try service.providerFields(service.expandedConfig(candidate.file.updatedData))
            .first(where: { $0.0 == candidate.probeProvider })
        let freshCache = candidate.freshSource ? editedProvider.flatMap { ProxyProviderProbe.cacheURL(of: $0.1, home: localHome) } : nil
        let previousNames = document.activeNames
        let nextNames = candidate.document.activeNames
        do {
            _ = try await transaction.commit(
                candidate.file,
                validate: { path in
                    do { try await self.processManager.validateConfig(configPath: path) }
                    catch { throw NativeProxyProviderError.invalidConfig }
                    guard !self.isRemoteTarget, self.isSelectedRoutingConfig(document.configURL),
                          self.processManager.status == status else { throw QuickRuleError.contextChanged }
                    if let client {
                        let previous: ProviderSummary = try await client.request(.proxyProviders)
                        guard Set(self.visibleRuntimeProviders(previous.providers).keys) == previousNames,
                              self.appliedProviderConfig?.data == document.data,
                              freshCache.map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true
                        else { throw QuickRuleError.contextChanged }
                        let runtime: [String: JSONValue] = try await client.request(.getConfigs)
                        nextPayload = try transaction.reloadPayload(candidate.file.updatedData, runtime: runtime)
                        previousPayload = try transaction.reloadPayload(document.data, runtime: runtime)
                    }
                },
                didWrite: { self.acknowledgeQuickRuleConfigWrite(document.configURL) },
                apply: {
                    guard let client else { return }
                    didAttemptReload = true
                    try await client.requestNoResponse(.putConfigs(force: false, path: "", payload: nextPayload))
                    async let response: ProviderSummary = client.request(.proxyProviders)
                    async let groups: ProxyGroupsResponse = client.request(.proxies)
                    let (summary, resolved) = try await (response, groups)
                    let native = self.visibleRuntimeProviders(summary.providers)
                    guard self.processManager.status == status, Set(native.keys) == nextNames,
                          native.values.allSatisfy({ $0.proxies?.isEmpty == false }),
                          freshCache.map({ FileManager.default.fileExists(atPath: $0.path) }) ?? true,
                          editedProvider.map({ provider in
                              let expected = inspected?.nodes[provider.0]
                              return expected == nil || native[provider.0]?.proxies?.map(\.name) == expected
                          }) ?? true,
                          candidate.affectedGroups.allSatisfy({ resolved.proxies[$0] != nil }),
                          Self.emptyAffectedGroups(candidate, in: resolved.proxies).isSubset(of: allowedEmptyGroups)
                    else { throw NativeProxyProviderError.reloadFailed }
                    // Replace provider and group snapshots together, discarding old provider node latency.
                    let changedNodes = self.proxyProvidersDetail.values.flatMap { ($0.proxies ?? []).map(\.name) }
                    for node in changedNodes { self.proxyLatencyHistory.removeValue(forKey: node) }
                    self.applyProxyGroupsResponse(resolved, proxyProviders: summary.providers)
                },
                restoreRuntime: {
                    guard let client, self.processManager.status == status else { throw NativeProxyProviderError.reloadFailed }
                    try await client.requestNoResponse(.putConfigs(force: false, path: "", payload: previousPayload))
                    let restored: ProviderSummary = try await client.request(.proxyProviders)
                    guard self.processManager.status == status, Set(self.visibleRuntimeProviders(restored.providers).keys) == previousNames,
                          self.visibleRuntimeProviders(restored.providers).values.allSatisfy({ $0.proxies?.isEmpty == false })
                    else { throw NativeProxyProviderError.reloadFailed }
                    rollbackVerified = true
                })
        } catch {
            if didAttemptReload && !rollbackVerified {
                self.appliedProviderConfig = nil
                self.clearProxyPresentation()
            }
            if let error = error as? QuickRuleError { throw error }
            if let error = error as? NativeProxyProviderError { throw error }
            if error is CancellationError { throw error }
            throw didAttemptReload ? NativeProxyProviderError.reloadFailed : NativeProxyProviderError.invalidConfig
        }
        if activeFile { self.rememberAppliedProviderConfig(url: document.configURL, data: candidate.file.updatedData) }
        self.nativeProxyProviderNotice = self.tr(activeFile ? "ui.proxy_provider.saved" : "ui.native_rule.saved_file")
        return activeFile
    }

    private static func emptyAffectedGroups(_ candidate: NativeProxyProviderEdit, in groups: [String: ProxyGroup]) -> Set<String> {
        Set(candidate.affectedGroups.filter { name in
            guard let group = groups[name] else { return false }
            return group.all.isEmpty || group.all == ["COMPATIBLE"]
        })
    }

    func proxyProviderErrorText(_ error: Error) -> String {
        guard let error = error as? NativeProxyProviderError else {
            return error is QuickRuleError ? self.quickRuleErrorText(error) : self.tr("ui.proxy_provider.error.config")
        }
        switch error {
        case .invalidConfig: return self.tr("ui.proxy_provider.error.config")
        case .invalidName: return self.tr("ui.proxy_provider.error.name")
        case .invalidURL: return self.tr("ui.proxy_provider.error.url")
        case .invalidInterval: return self.tr("ui.proxy_provider.error.interval")
        case .conflict: return self.tr("ui.proxy_provider.error.conflict")
        case .unavailable: return self.tr("ui.proxy_provider.error.core")
        case .sourceFailed: return self.tr("ui.proxy_provider.error.source")
        case .reloadFailed: return self.tr("ui.proxy_provider.error.reload")
        case .emptyGroups(let names): return self.tr("ui.proxy_provider.error.empty_groups", names.joined(separator: ", "))
        }
    }
}
