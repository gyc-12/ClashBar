import Foundation

struct ApplicationCatalogService: Sendable {
    let roots: [URL]
    init(roots: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        URL(fileURLWithPath: "/System/Applications"),
    ]) { self.roots = roots }

    func applications() async -> [ApplicationRoutingCandidate] {
        let task = Task.detached(priority: .userInitiated) { self.scan() }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func scan() -> [ApplicationRoutingCandidate] {
        var results: [ApplicationRoutingCandidate] = []
        var seen: Set<String> = []
        for root in self.roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                if Task.isCancelled { return results }
                if enumerator.level > 4 { enumerator.skipDescendants(); continue }
                guard url.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                if let candidate = try? Self.application(at: url), seen.insert(candidate.id).inserted {
                    results.append(candidate)
                }
            }
        }
        return results.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func application(at url: URL) throws -> ApplicationRoutingCandidate {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
            let executable = bundle.executableURL?.resolvingSymlinksInPath(),
            FileManager.default.isExecutableFile(atPath: executable.path)
        else { throw ApplicationRoutingError.invalidApplication }
        let path = try ApplicationRoutingCandidate.validatedTarget(executable.path, type: .processPath)
        let process = try ApplicationRoutingCandidate.validatedTarget(executable.lastPathComponent, type: .processName)
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return ApplicationRoutingCandidate(name: name, processName: process, processPath: path, bundlePath: url.path)
    }
}
