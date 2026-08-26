import Foundation
import PeekabooFoundation

/// The presentation role declared by an installed application's Info.plist.
public enum ServiceInstalledApplicationPresentation: String, Codable, Sendable, Equatable, CaseIterable {
    case regular
    case uiElement = "ui_element"
    case backgroundOnly = "background_only"
}

/// Read-only metadata for an application bundle found in a standard macOS installation root.
public struct ServiceInstalledApplicationInfo: Codable, Sendable, Equatable {
    public let name: String
    public let bundleIdentifier: String
    public let launchPath: String
    public let declaredPresentation: ServiceInstalledApplicationPresentation

    public init(
        name: String,
        bundleIdentifier: String,
        launchPath: String,
        declaredPresentation: ServiceInstalledApplicationPresentation)
    {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.launchPath = launchPath
        self.declaredPresentation = declaredPresentation
    }
}

public struct ServiceInstalledApplicationListData: Codable, Sendable, Equatable {
    public let applications: [ServiceInstalledApplicationInfo]

    public init(applications: [ServiceInstalledApplicationInfo]) {
        self.applications = applications
    }
}

/// Additive service capability for filesystem-backed installed application discovery.
public protocol InstalledApplicationCatalogProviding: Sendable {
    var supportsInstalledApplicationCatalog: Bool { get }

    @MainActor
    func listInstalledApplications() async throws
        -> UnifiedToolOutput<ServiceInstalledApplicationListData>
}

/// Keeps installed inventory separate from live process identity.
public enum InstalledApplicationReconciler {
    public static func installedButNotRunning(
        catalog: [ServiceInstalledApplicationInfo],
        running: [ServiceApplicationInfo]) -> [ServiceInstalledApplicationInfo]
    {
        guard !self.hasIdentityPoorRunningApplications(running) else { return [] }
        let runningBundleIdentifiers = Set(running.compactMap { application -> String? in
            guard let bundleIdentifier = application.bundleIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !bundleIdentifier.isEmpty
            else {
                return nil
            }
            return bundleIdentifier.lowercased()
        })
        return catalog.filter { application in
            !runningBundleIdentifiers.contains(application.bundleIdentifier.lowercased())
        }
    }

    public static func hasIdentityPoorRunningApplications(_ running: [ServiceApplicationInfo]) -> Bool {
        running.contains { application in
            let bundleIdentifier = application.bundleIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return bundleIdentifier?.isEmpty != false
        }
    }
}

actor InstalledApplicationCatalog {
    typealias ScanHandler = @Sendable () async throws
        -> UnifiedToolOutput<ServiceInstalledApplicationListData>
    typealias NowProvider = @Sendable () -> ContinuousClock.Instant

    static let shared = InstalledApplicationCatalog()

    private struct CachedResult: Sendable {
        let output: UnifiedToolOutput<ServiceInstalledApplicationListData>
        let expiresAt: ContinuousClock.Instant
    }

    private struct ActiveScan: Sendable {
        let id: UUID
        let task: Task<UnifiedToolOutput<ServiceInstalledApplicationListData>, any Error>
    }

    private let scanHandler: ScanHandler
    private let now: NowProvider
    private let cacheDuration: Duration
    private let hardTimeout: Duration
    private var cachedResult: CachedResult?
    private var activeScan: ActiveScan?
    private var timedOutScanID: UUID?

    init(
        cacheDuration: Duration = .seconds(2),
        hardTimeout: Duration = .seconds(2),
        now: @escaping NowProvider = { ContinuousClock.now },
        scanHandler: ScanHandler? = nil)
    {
        self.cacheDuration = cacheDuration
        self.hardTimeout = hardTimeout
        self.now = now
        self.scanHandler = scanHandler ?? {
            try await Task.detached(priority: .utility) {
                try InstalledApplicationCatalogScanner(timeout: .milliseconds(1750)).scan()
            }.value
        }
    }

    func listApplications() async throws -> UnifiedToolOutput<ServiceInstalledApplicationListData> {
        try Task.checkCancellation()
        let current = self.now()
        if let cachedResult = self.cachedResult, current < cachedResult.expiresAt {
            return cachedResult.output
        }
        if self.timedOutScanID != nil {
            throw Self.timeoutError(timeout: self.hardTimeout, quarantined: true)
        }

        let activeScan: ActiveScan
        if let existing = self.activeScan {
            activeScan = existing
        } else {
            let id = UUID()
            let task = Task { try await self.scanHandler() }
            activeScan = ActiveScan(id: id, task: task)
            self.activeScan = activeScan
            Task.detached { [weak self] in
                let result = await task.result
                await self?.scanCompleted(id: id, result: result)
            }
        }

        do {
            let output = try await Self.awaitResult(of: activeScan.task, timeout: self.hardTimeout)
            try Task.checkCancellation()
            return output
        } catch is InstalledApplicationCatalogTimeoutError {
            self.markTimedOut(id: activeScan.id)
            throw Self.timeoutError(
                timeout: self.hardTimeout,
                quarantined: self.timedOutScanID == activeScan.id)
        } catch {
            throw error
        }
    }

    private func markTimedOut(id: UUID) {
        guard self.activeScan?.id == id else { return }
        self.timedOutScanID = id
        self.activeScan?.task.cancel()
    }

    private func scanCompleted(
        id: UUID,
        result: Result<UnifiedToolOutput<ServiceInstalledApplicationListData>, any Error>)
    {
        guard self.activeScan?.id == id else { return }
        self.activeScan = nil
        if self.timedOutScanID == id {
            self.timedOutScanID = nil
            return
        }
        if case let .success(output) = result, output.summary.status == .success {
            self.cachedResult = CachedResult(
                output: output,
                expiresAt: self.now().advanced(by: self.cacheDuration))
        }
    }

    private nonisolated static func awaitResult(
        of task: Task<UnifiedToolOutput<ServiceInstalledApplicationListData>, any Error>,
        timeout: Duration) async throws -> UnifiedToolOutput<ServiceInstalledApplicationListData>
    {
        let race = InstalledApplicationCatalogTimeoutRace<UnifiedToolOutput<ServiceInstalledApplicationListData>>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard race.setContinuation(continuation) else { return }
                let resultTask = Task {
                    _ = await race.resume(task.result)
                }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    _ = race.resume(.failure(InstalledApplicationCatalogTimeoutError()))
                }
                race.setTasks(result: resultTask, timeout: timeoutTask)
            }
        } onCancel: {
            race.cancel()
        }
    }

    private nonisolated static func timeoutError(timeout: Duration, quarantined: Bool) -> PeekabooError {
        let components = timeout.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        let suffix = quarantined
            ? " The blocked scan remains quarantined until its native filesystem call returns."
            : ""
        return PeekabooError.serviceUnavailable(
            "Installed application discovery exceeded its \(String(format: "%.1f", seconds))s deadline." + suffix)
    }
}

private struct InstalledApplicationCatalogTimeoutError: Error, Sendable {}

private final class InstalledApplicationCatalogTimeoutRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var terminalResult: Result<T, any Error>?
    private var resultTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func setContinuation(_ continuation: CheckedContinuation<T, any Error>) -> Bool {
        let terminalResult = self.lock.withLock { () -> Result<T, any Error>? in
            if let terminalResult = self.terminalResult {
                return terminalResult
            }
            self.continuation = continuation
            return nil
        }
        if let terminalResult {
            continuation.resume(with: terminalResult)
            return false
        }
        return true
    }

    func setTasks(result: Task<Void, Never>, timeout: Task<Void, Never>) {
        let shouldCancel = self.lock.withLock { () -> Bool in
            guard self.terminalResult == nil else { return true }
            self.resultTask = result
            self.timeoutTask = timeout
            return false
        }
        if shouldCancel {
            result.cancel()
            timeout.cancel()
        }
    }

    @discardableResult
    func resume(_ result: Result<T, any Error>) -> Bool {
        let state = self.lock.withLock { () -> (
            CheckedContinuation<T, any Error>?,
            Task<Void, Never>?,
            Task<Void, Never>?)? in
            guard self.terminalResult == nil else { return nil }
            self.terminalResult = result
            let state = (self.continuation, self.resultTask, self.timeoutTask)
            self.continuation = nil
            self.resultTask = nil
            self.timeoutTask = nil
            return state
        }
        guard let state else { return false }
        state.1?.cancel()
        state.2?.cancel()
        state.0?.resume(with: result)
        return true
    }

    func cancel() {
        _ = self.resume(.failure(CancellationError()))
    }
}

struct InstalledApplicationCatalogScanner: Sendable {
    struct Root: Sendable, Equatable {
        let url: URL
        let priority: Int
        let label: String
    }

    private struct Candidate: Sendable {
        let application: ServiceInstalledApplicationInfo
        let canonicalPath: String
        let rootPriority: Int
    }

    let roots: [Root]
    let maximumVisitedEntries: Int
    let timeout: Duration

    init(
        roots: [Root] = Self.defaultRoots(),
        maximumVisitedEntries: Int = 50000,
        timeout: Duration = .milliseconds(1750))
    {
        self.roots = roots
        self.maximumVisitedEntries = maximumVisitedEntries
        self.timeout = timeout
    }

    func scan() throws -> UnifiedToolOutput<ServiceInstalledApplicationListData> {
        let startedAt = Date()
        let deadline = ContinuousClock.now.advanced(by: self.timeout)
        let fileManager = FileManager.default
        let roots = Self.deduplicatedRoots(self.roots, fileManager: fileManager)
        var candidates: [Candidate] = []
        var warnings: [String] = []
        var readableRootCount = 0
        var visitedEntryCount = 0
        var reachedBound = false

        for root in roots {
            try Task.checkCancellation()
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }

            var rootWarnings: [String] = []
            guard let enumerator = fileManager.enumerator(
                at: root.url,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants],
                errorHandler: { url, error in
                    rootWarnings.append("Could not read \(url.path): \(error.localizedDescription)")
                    return true
                })
            else {
                warnings.append("Could not enumerate installed application root \(root.url.path)")
                continue
            }
            readableRootCount += 1

            while let item = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                visitedEntryCount += 1
                if visitedEntryCount > self.maximumVisitedEntries {
                    warnings.append(
                        "Installed application catalog stopped after \(self.maximumVisitedEntries) filesystem entries")
                    reachedBound = true
                    break
                }
                if ContinuousClock.now >= deadline {
                    warnings
                        .append("Installed application catalog exceeded its \(Self.seconds(self.timeout))s deadline")
                    reachedBound = true
                    break
                }
                guard item.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { continue }
                if let candidate = Self.candidate(at: item, root: root, warnings: &warnings) {
                    candidates.append(candidate)
                }
                if ContinuousClock.now >= deadline {
                    warnings
                        .append("Installed application catalog exceeded its \(Self.seconds(self.timeout))s deadline")
                    reachedBound = true
                    break
                }
            }
            if !reachedBound, ContinuousClock.now >= deadline {
                warnings.append("Installed application catalog exceeded its \(Self.seconds(self.timeout))s deadline")
                reachedBound = true
            }
            warnings.append(contentsOf: rootWarnings)
            if reachedBound {
                break
            }
        }

        guard readableRootCount > 0 else {
            throw PeekabooError.serviceUnavailable(
                "No standard macOS application directory was available for installed application discovery")
        }

        let applications = Self.deduplicatedApplications(candidates, warnings: &warnings)
        warnings = Array(Set(warnings)).sorted()
        return UnifiedToolOutput(
            data: ServiceInstalledApplicationListData(applications: applications),
            summary: .init(
                brief: "Found \(applications.count) installed application\(applications.count == 1 ? "" : "s")",
                status: warnings.isEmpty ? .success : .partial,
                counts: [
                    "applications": applications.count,
                    "visitedEntries": visitedEntryCount,
                    "readableRoots": readableRootCount,
                ]),
            metadata: .init(
                duration: Date().timeIntervalSince(startedAt),
                warnings: warnings,
                hints: ["Installed paths are discovery metadata, not process or mutation receipts"]))
    }

    static func defaultRoots(fileManager: FileManager = .default) -> [Root] {
        var roots: [Root] = []
        let applicationDomains: [(FileManager.SearchPathDomainMask, Int, String)] = [
            (.userDomainMask, 0, "user applications"),
            (.localDomainMask, 10, "local applications"),
            (.systemDomainMask, 20, "system applications"),
        ]
        for (domain, priority, label) in applicationDomains {
            roots.append(contentsOf: fileManager.urls(for: .applicationDirectory, in: domain).map {
                Root(url: $0, priority: priority, label: label)
            })
        }
        let coreServiceDomains: [(FileManager.SearchPathDomainMask, Int, String)] = [
            (.localDomainMask, 11, "local core services"),
            (.systemDomainMask, 21, "system core services"),
        ]
        for (domain, priority, label) in coreServiceDomains {
            roots.append(contentsOf: fileManager.urls(for: .coreServiceDirectory, in: domain).map {
                Root(url: $0, priority: priority, label: label)
            })
        }

        let cryptexPaths = [
            "/System/Cryptexes/App/System/Applications",
            "/System/Cryptexes/App/System/Library/CoreServices",
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
            "/System/Volumes/Preboot/Cryptexes/App/System/Library/CoreServices",
        ]
        roots.append(contentsOf: cryptexPaths.enumerated().map { index, path in
            Root(url: URL(fileURLWithPath: path), priority: 30 + index, label: "system Cryptex applications")
        })
        return roots
    }

    private static func deduplicatedRoots(_ roots: [Root], fileManager: FileManager) -> [Root] {
        let sorted = roots.sorted { lhs, rhs in
            lhs.priority == rhs.priority ? lhs.url.path < rhs.url.path : lhs.priority < rhs.priority
        }
        var seen = Set<String>()
        return sorted.filter { root in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return true
            }
            return seen.insert(Self.canonicalPath(root.url)).inserted
        }
    }

    private static func candidate(
        at url: URL,
        root: Root,
        warnings: inout [String]) -> Candidate?
    {
        let standardizedURL = url.standardizedFileURL
        guard let bundle = Bundle(url: standardizedURL) else {
            warnings.append("Skipped installed application at \(standardizedURL.path): unreadable bundle metadata")
            return nil
        }
        guard let bundleIdentifier = Self.nonemptyString(bundle.bundleIdentifier) else {
            warnings.append("Skipped installed application at \(standardizedURL.path): missing CFBundleIdentifier")
            return nil
        }
        let name = Self.nonemptyString(bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? Self.nonemptyString(bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? standardizedURL.deletingPathExtension().lastPathComponent
        guard !name.isEmpty else {
            warnings.append("Skipped installed application at \(standardizedURL.path): missing application name")
            return nil
        }

        let isBackgroundOnly = Self.infoBoolean(bundle.object(forInfoDictionaryKey: "LSBackgroundOnly"))
        let isUIElement = Self.infoBoolean(bundle.object(forInfoDictionaryKey: "LSUIElement"))
        if isBackgroundOnly, isUIElement {
            warnings.append(
                "Installed application \(bundleIdentifier) declares both LSBackgroundOnly and LSUIElement; " +
                    "classified as background_only")
        }
        let presentation: ServiceInstalledApplicationPresentation = if isBackgroundOnly {
            .backgroundOnly
        } else if isUIElement {
            .uiElement
        } else {
            .regular
        }
        return Candidate(
            application: ServiceInstalledApplicationInfo(
                name: name,
                bundleIdentifier: bundleIdentifier,
                launchPath: standardizedURL.path,
                declaredPresentation: presentation),
            canonicalPath: Self.canonicalPath(standardizedURL),
            rootPriority: root.priority)
    }

    private static func deduplicatedApplications(
        _ candidates: [Candidate],
        warnings: inout [String]) -> [ServiceInstalledApplicationInfo]
    {
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.rootPriority != rhs.rootPriority {
                return lhs.rootPriority < rhs.rootPriority
            }
            if lhs.canonicalPath != rhs.canonicalPath {
                return lhs.canonicalPath < rhs.canonicalPath
            }
            return lhs.application.bundleIdentifier < rhs.application.bundleIdentifier
        }
        var seenPaths = Set<String>()
        var selectedByBundleIdentifier: [String: ServiceInstalledApplicationInfo] = [:]
        for candidate in ordered {
            guard seenPaths.insert(candidate.canonicalPath).inserted else { continue }
            let bundleKey = candidate.application.bundleIdentifier.lowercased()
            if let selected = selectedByBundleIdentifier[bundleKey] {
                warnings.append(
                    "Duplicate installed application bundle ID \(candidate.application.bundleIdentifier) at " +
                        "\(selected.launchPath) and \(candidate.application.launchPath); " +
                        "selected \(selected.launchPath)")
                continue
            }
            selectedByBundleIdentifier[bundleKey] = candidate.application
        }
        return selectedByBundleIdentifier.values.sorted { lhs, rhs in
            let lhsName = Self.sortKey(lhs.name)
            let rhsName = Self.sortKey(rhs.name)
            if lhsName != rhsName {
                return lhsName < rhsName
            }
            let lhsBundle = lhs.bundleIdentifier.lowercased()
            let rhsBundle = rhs.bundleIdentifier.lowercased()
            return lhsBundle == rhsBundle ? lhs.launchPath < rhs.launchPath : lhsBundle < rhsBundle
        }
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func nonemptyString(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func infoBoolean(_ value: Any?) -> Bool {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        if let value = value as? String {
            return (value as NSString).boolValue
        }
        return false
    }

    private static func sortKey(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func seconds(_ duration: Duration) -> String {
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return String(format: "%.1f", seconds)
    }
}

extension ApplicationService: InstalledApplicationCatalogProviding {
    public nonisolated var supportsInstalledApplicationCatalog: Bool {
        true
    }

    public func listInstalledApplications() async throws
        -> UnifiedToolOutput<ServiceInstalledApplicationListData>
    {
        try await InstalledApplicationCatalog.shared.listApplications()
    }
}
