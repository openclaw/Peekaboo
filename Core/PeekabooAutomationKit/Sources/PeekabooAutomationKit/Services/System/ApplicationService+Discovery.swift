import AppKit
import Foundation
import PeekabooFoundation

private struct ApplicationInventoryCandidate: Sendable {
    let processIdentifier: pid_t
    let processStartIdentity: UInt64?
    let windows: [WindowIdentityInfo]
    let windowCatalogAvailable: Bool
    let fallbackName: String?
    let isActive: Bool
}

private enum ApplicationInventoryOutcome: Sendable {
    case metadata(DetachedApplicationMetadata)
    case timedOut(seconds: TimeInterval)
    case skippedAfterOverallDeadline(seconds: TimeInterval)
    case unavailable
    case processChanged
}

private struct ApplicationInventoryRead: Sendable {
    let candidate: ApplicationInventoryCandidate
    let outcome: ApplicationInventoryOutcome
}

@MainActor
extension ApplicationService {
    public func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData> {
        let startTime = Date()
        self.logger.info("Listing all running applications")

        let processIdentifiers = Array(Set(self.runningApplicationProcessIdentifiersProvider()))
            .filter { $0 > 0 }
        let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let windowCatalog = self.applicationWindowCatalogProvider()
        let windowsByProcessIdentifier = Dictionary(grouping: windowCatalog ?? [], by: \.ownerPID)
        let candidates = processIdentifiers.map { processIdentifier in
            let rawWindows = windowsByProcessIdentifier[processIdentifier] ?? []
            let renderableWindows = rawWindows.filter(\.isRenderable)
            return ApplicationInventoryCandidate(
                processIdentifier: processIdentifier,
                processStartIdentity: self.processStartIdentityProvider(processIdentifier),
                windows: renderableWindows.isEmpty ? rawWindows : renderableWindows,
                windowCatalogAvailable: windowCatalog != nil,
                fallbackName: rawWindows.lazy.compactMap(\.applicationName).first,
                isActive: frontmostProcessIdentifier == processIdentifier)
        }
        self.logger.debug("Found \(candidates.count) running processes")

        let metadataProvider = self.applicationMetadataProvider
        let metadataTimeout = self.applicationMetadataTimeout
        let overallTimeout = self.applicationInventoryOverallTimeout
        let overallDeadline = self.applicationInventoryNowProvider().advanced(by: .seconds(overallTimeout))
        let concurrencyLimit = min(self.maximumConcurrentApplicationMetadataReads, candidates.count)
        let reads = try await withThrowingTaskGroup(of: ApplicationInventoryRead.self) { group in
            var results: [ApplicationInventoryRead] = []
            results.reserveCapacity(candidates.count)
            var nextCandidateIndex = 0
            while nextCandidateIndex < concurrencyLimit {
                guard let timeout = Self.remainingApplicationMetadataTimeout(
                    now: self.applicationInventoryNowProvider(),
                    overallDeadline: overallDeadline,
                    perApplicationTimeout: metadataTimeout)
                else {
                    results.append(contentsOf: candidates[nextCandidateIndex...].map { candidate in
                        ApplicationInventoryRead(
                            candidate: candidate,
                            outcome: .skippedAfterOverallDeadline(seconds: overallTimeout))
                    })
                    nextCandidateIndex = candidates.count
                    break
                }
                let candidate = candidates[nextCandidateIndex]
                nextCandidateIndex += 1
                group.addTask {
                    try await Self.readApplicationMetadata(
                        candidate: candidate,
                        provider: metadataProvider,
                        timeout: timeout)
                }
            }

            while let read = try await group.next() {
                results.append(read)
                if nextCandidateIndex < candidates.count {
                    if let timeout = Self.remainingApplicationMetadataTimeout(
                        now: self.applicationInventoryNowProvider(),
                        overallDeadline: overallDeadline,
                        perApplicationTimeout: metadataTimeout)
                    {
                        let candidate = candidates[nextCandidateIndex]
                        nextCandidateIndex += 1
                        group.addTask {
                            try await Self.readApplicationMetadata(
                                candidate: candidate,
                                provider: metadataProvider,
                                timeout: timeout)
                        }
                    } else {
                        results.append(contentsOf: candidates[nextCandidateIndex...].map { candidate in
                            ApplicationInventoryRead(
                                candidate: candidate,
                                outcome: .skippedAfterOverallDeadline(seconds: overallTimeout))
                        })
                        nextCandidateIndex = candidates.count
                    }
                }
            }
            return results
        }
        try Task.checkCancellation()

        let applications = reads.compactMap { read -> ServiceApplicationInfo? in
            if let expectedGeneration = read.candidate.processStartIdentity,
               self.processStartIdentityProvider(read.candidate.processIdentifier) != expectedGeneration
            {
                return nil
            }
            return self.applicationInfo(from: read)
        }.sorted { app1, app2 -> Bool in
            app1.name == app2.name
                ? app1.processIdentifier < app2.processIdentifier
                : app1.name < app2.name
        }
        let warnings = Self.uniqueWarnings(in: applications)

        self.logger.info("Returning \(applications.count) applications")

        // Find active app and calculate counts
        let activeApp = applications.first { $0.isActive }
        let appsWithWindows = applications.filter { $0.windowCount > 0 }
        let totalWindows = applications.reduce(0) { $0 + $1.windowCount }

        // Build highlights
        var highlights: [UnifiedToolOutput<ServiceApplicationListData>.Summary.Highlight] = []
        if let active = activeApp {
            highlights.append(.init(
                label: active.name,
                value: "\(active.windowCount) window\(active.windowCount == 1 ? "" : "s")",
                kind: .primary))
        }

        return UnifiedToolOutput(
            data: ServiceApplicationListData(applications: applications),
            summary: UnifiedToolOutput.Summary(
                brief: "Found \(applications.count) running application\(applications.count == 1 ? "" : "s")",
                detail: nil,
                status: warnings.isEmpty ? .success : .partial,
                counts: [
                    "applications": applications.count,
                    "appsWithWindows": appsWithWindows.count,
                    "totalWindows": totalWindows,
                    "incompleteApplications": applications.count(where: { !($0.metadataWarnings ?? []).isEmpty }),
                ],
                highlights: highlights),
            metadata: UnifiedToolOutput.Metadata(
                duration: Date().timeIntervalSince(startTime),
                warnings: warnings,
                hints: ["Use app name or PID to target specific application"]))
    }

    private func applicationInfo(from read: ApplicationInventoryRead) -> ServiceApplicationInfo? {
        let candidate = read.candidate
        let windowIDs = candidate.windowCatalogAvailable ? candidate.windows.map { Int($0.windowID) } : nil
        var warnings: [String] = candidate.windowCatalogAvailable
            ? []
            : ["Window inventory was unavailable for PID \(candidate.processIdentifier)"]

        switch read.outcome {
        case let .metadata(metadata):
            guard let name = metadata.name, !name.isEmpty else { return nil }
            return ServiceApplicationInfo(
                processIdentifier: candidate.processIdentifier,
                processStartIdentity: candidate.processStartIdentity,
                bundleIdentifier: metadata.bundleIdentifier,
                name: name,
                bundlePath: metadata.bundlePath,
                isActive: candidate.isActive,
                isHidden: metadata.isHidden,
                isHiddenKnown: true,
                windowCount: candidate.windows.count,
                windowIDs: windowIDs,
                activationPolicy: metadata.activationPolicy,
                isFinishedLaunching: metadata.isFinishedLaunching,
                metadataWarnings: warnings.isEmpty ? nil : warnings)
        case let .timedOut(seconds):
            guard candidate.processStartIdentity != nil else { return nil }
            warnings.append(
                "Application metadata timed out after \(Self.formatInventoryTimeout(seconds))s for PID " +
                    "\(candidate.processIdentifier); hidden state and activation policy are unknown")
        case let .skippedAfterOverallDeadline(seconds):
            guard candidate.processStartIdentity != nil else { return nil }
            warnings.append(
                "Application metadata was skipped after the \(Self.formatInventoryTimeout(seconds))s inventory " +
                    "deadline for PID \(candidate.processIdentifier); hidden state and activation policy are unknown")
        case .unavailable:
            guard candidate.processStartIdentity != nil else { return nil }
            warnings.append(
                "Application metadata was unavailable for PID \(candidate.processIdentifier); " +
                    "hidden state and activation policy are unknown")
        case .processChanged:
            return nil
        }

        return ServiceApplicationInfo(
            processIdentifier: candidate.processIdentifier,
            processStartIdentity: candidate.processStartIdentity,
            bundleIdentifier: nil,
            name: candidate.fallbackName ?? "PID \(candidate.processIdentifier)",
            isActive: candidate.isActive,
            isHidden: false,
            isHiddenKnown: false,
            windowCount: candidate.windows.count,
            windowIDs: windowIDs,
            activationPolicy: nil,
            isFinishedLaunching: nil,
            metadataWarnings: warnings)
    }

    private nonisolated static func readApplicationMetadata(
        candidate: ApplicationInventoryCandidate,
        provider: ApplicationService.ApplicationMetadataProvider,
        timeout: TimeInterval) async throws -> ApplicationInventoryRead
    {
        do {
            let metadata = try await provider(
                candidate.processIdentifier,
                candidate.processStartIdentity,
                timeout)
            try Task.checkCancellation()
            return ApplicationInventoryRead(candidate: candidate, outcome: .metadata(metadata))
        } catch is CancellationError {
            throw CancellationError()
        } catch let CaptureError.detectionTimedOut(seconds) {
            return ApplicationInventoryRead(candidate: candidate, outcome: .timedOut(seconds: seconds))
        } catch let error as PeekabooError {
            if case .snapshotStale = error {
                return ApplicationInventoryRead(candidate: candidate, outcome: .processChanged)
            }
            return ApplicationInventoryRead(candidate: candidate, outcome: .unavailable)
        } catch {
            return ApplicationInventoryRead(candidate: candidate, outcome: .unavailable)
        }
    }

    private static func uniqueWarnings(in applications: [ServiceApplicationInfo]) -> [String] {
        applications.reduce(into: []) { result, application in
            for warning in application.metadataWarnings ?? [] where !result.contains(warning) {
                result.append(warning)
            }
        }
    }

    private static func formatInventoryTimeout(_ seconds: TimeInterval) -> String {
        String(format: "%.2f", seconds)
    }

    private static func remainingApplicationMetadataTimeout(
        now: ContinuousClock.Instant,
        overallDeadline: ContinuousClock.Instant,
        perApplicationTimeout: TimeInterval) -> TimeInterval?
    {
        let remaining = now.duration(to: overallDeadline)
        guard remaining > .zero else { return nil }
        let components = remaining.components
        let remainingSeconds = TimeInterval(components.seconds) +
            TimeInterval(components.attoseconds) / 1e18
        return min(perApplicationTimeout, remainingSeconds)
    }

    /**
     * Find a specific application using flexible identification formats.
     *
     * - Parameter identifier: Application identifier in one of these formats:
     *   - Process ID: `"PID:1234"` for direct process lookup
     *   - Bundle ID: `"com.apple.Safari"` for exact bundle identifier matching
     *   - App Name: `"Safari"` for case-insensitive name matching
     *   - Partial Name: `"Saf"` for fuzzy matching when exact match fails
     * - Returns: `ServiceApplicationInfo` containing application details and window count
     * - Throws: `PeekabooError.appNotFound` if no matching application is found
     *
     * ## Matching Priority
     * 1. Exact PID match (if identifier starts with "PID:")
     * 2. Exact bundle ID match
     * 3. Exact name match (case-insensitive)
     * 4. Fuzzy partial name match
     * 5. GUI applications preferred over background processes
     *
     * ## Examples
     * ```swift
     * // Find by exact name
     * let safari = try await appService.findApplication(identifier: "Safari")
     *
     * // Find by process ID
     * let app = try await appService.findApplication(identifier: "PID:1234")
     *
     * // Find by bundle ID
     * let chrome = try await appService.findApplication(identifier: "com.google.Chrome")
     *
     * // Fuzzy match
     * let xcode = try await appService.findApplication(identifier: "Xcod") // Matches "Xcode"
     * ```
     */
    public func findApplication(identifier: String) async throws -> ServiceApplicationInfo {
        self.logger.info("Finding application with identifier: \(identifier, privacy: .public)")

        // Trim whitespace from identifier to handle edge cases
        let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)

        let runningApps = NSWorkspace.shared.runningApplications.filter { app in
            !app.isTerminated
        }

        // 1. Try PID match (highest priority)
        if let pid = Self.parsePID(trimmedIdentifier),
           let app = runningApps.first(where: { $0.processIdentifier == pid })
        {
            return self.createApplicationInfo(from: app)
        }

        // 2. Try exact bundle ID match
        if let bundleMatch = runningApps.first(where: { $0.bundleIdentifier == trimmedIdentifier }) {
            return self.createApplicationInfo(from: bundleMatch)
        }

        // 3. Try exact name match (case-insensitive)
        if let exactName = runningApps.first(where: {
            guard let name = $0.localizedName else { return false }
            return name.compare(trimmedIdentifier, options: .caseInsensitive) == .orderedSame
        }) {
            return self.createApplicationInfo(from: exactName)
        }

        // 4. Try exact executable-name match (case-insensitive)
        // The process/binary name shown by ps, pgrep, and Activity Monitor often differs
        // from the localized app name (e.g. an app whose CFBundleName is
        // "OpenClaw Desktop Test" ships an "openclaw-desktop" binary).
        if let exactExecutable = runningApps.first(where: {
            guard let executable = $0.executableURL?.lastPathComponent else { return false }
            return executable.compare(trimmedIdentifier, options: .caseInsensitive) == .orderedSame
        }) {
            return self.createApplicationInfo(from: exactExecutable)
        }

        // 5. Fuzzy matching with prioritization
        // Collect all fuzzy matches (localized name or executable name) and sort by relevance
        let fuzzyMatches = runningApps.compactMap { app -> (app: NSRunningApplication, score: Int)? in
            guard app.activationPolicy != .prohibited, let name = app.localizedName else { return nil }
            let executable = app.executableURL?.lastPathComponent
            let nameMatches = name.localizedCaseInsensitiveContains(trimmedIdentifier)
            let executableMatches = executable?.localizedCaseInsensitiveContains(trimmedIdentifier) ?? false
            guard nameMatches || executableMatches else { return nil }

            // Calculate match score (higher is better)
            var score = 0

            let lowercaseIdentifier = trimmedIdentifier.lowercased()

            // Exact match gets highest score; an exact executable match ranks just below
            // an exact localized-name match.
            if name.compare(trimmedIdentifier, options: .caseInsensitive) == .orderedSame {
                score += 1000
            }
            if let executable, executable.compare(trimmedIdentifier, options: .caseInsensitive) == .orderedSame {
                score += 800
            }

            // Name / executable starts with identifier gets high score
            if name.lowercased().hasPrefix(lowercaseIdentifier) {
                score += 100
            }
            if let executable, executable.lowercased().hasPrefix(lowercaseIdentifier) {
                score += 80
            }

            // Prefer regular apps over accessories/helpers
            if app.activationPolicy == .regular {
                score += 50
            }

            // Prefer shorter names (penalize longer names)
            // This helps prefer "Safari" over "Safari Web Content"
            score -= name.count

            return (app, score)
        }

        // Sort by score (descending) and return the best match
        if let bestMatch = fuzzyMatches.max(by: { $0.score < $1.score }) {
            let matchedName = bestMatch.app.localizedName ?? "unknown"
            self.logger
                .debug("Fuzzy match found: '\(trimmedIdentifier)' → '\(matchedName)' (score: \(bestMatch.score))")
            return self.createApplicationInfo(from: bestMatch.app)
        }

        self.logger.error("Application not found: \(identifier, privacy: .public)")
        throw PeekabooError.appNotFound(identifier)
    }

    static func parsePID(_ identifier: String) -> Int32? {
        guard identifier.uppercased().hasPrefix("PID:") else { return nil }
        return Int32(identifier.dropFirst(4))
    }

    public func getFrontmostApplication() async throws -> ServiceApplicationInfo {
        self.logger.info("Getting frontmost application")

        // Already on main thread due to @MainActor on class
        guard let app = NSWorkspace.shared.frontmostApplication else {
            self.logger.error("No frontmost application found")
            throw PeekabooError.appNotFound("frontmost")
        }

        self.logger.debug("Frontmost app: \(app.localizedName ?? "Unknown") (PID: \(app.processIdentifier))")
        return self.createApplicationInfo(from: app)
    }

    public func isApplicationRunning(identifier: String) async -> Bool {
        self.logger.debug("Checking if application is running: \(identifier)")
        do {
            _ = try await self.findApplication(identifier: identifier)
            self.logger.debug("Application is running: \(identifier)")
            return true
        } catch {
            self.logger.debug("Application is not running: \(identifier)")
            return false
        }
    }

    func createApplicationInfo(from app: NSRunningApplication) -> ServiceApplicationInfo {
        let processStartIdentityBeforeRead = self.processStartIdentityProvider(app.processIdentifier)
        let windows = self.getWindowIdentities(for: app)
        let processStartIdentityAfterRead = self.processStartIdentityProvider(app.processIdentifier)
        let stableProcessStartIdentity: UInt64? = if !app.isTerminated,
                                                     processStartIdentityBeforeRead == processStartIdentityAfterRead
        {
            processStartIdentityBeforeRead
        } else {
            nil
        }
        return ServiceApplicationInfo(
            processIdentifier: app.processIdentifier,
            processStartIdentity: stableProcessStartIdentity,
            bundleIdentifier: app.bundleIdentifier,
            name: app.localizedName ?? "Unknown",
            bundlePath: app.bundleURL?.path,
            isActive: app.isActive,
            isHidden: app.isHidden,
            isHiddenKnown: true,
            windowCount: windows.count,
            windowIDs: windows.map { Int($0.windowID) },
            activationPolicy: Self.serviceActivationPolicy(from: app.activationPolicy),
            isFinishedLaunching: app.isFinishedLaunching)
    }

    nonisolated static func serviceActivationPolicy(
        from policy: NSApplication.ActivationPolicy) -> ServiceApplicationActivationPolicy
    {
        switch policy {
        case .regular:
            .regular
        case .accessory:
            .accessory
        case .prohibited:
            .prohibited
        @unknown default:
            .unknown
        }
    }

    @MainActor
    private func getWindowCount(for app: NSRunningApplication) -> Int {
        self.getWindowIdentities(for: app).count
    }

    @MainActor
    private func getWindowIdentities(for app: NSRunningApplication) -> [WindowIdentityInfo] {
        let cgWindows = self.windowIdentityService.getWindows(for: app)
        if cgWindows.isEmpty {
            return []
        }

        let renderable = cgWindows.filter(\.isRenderable)
        return renderable.isEmpty ? cgWindows : renderable
    }

    public func getApplicationWithWindowCount(identifier: String) async throws -> ServiceApplicationInfo {
        self.logger.info("Getting application with window count: \(identifier)")
        var appInfo = try await findApplication(identifier: identifier)

        // Now query window count only for this specific app
        let runningApp = NSRunningApplication(processIdentifier: appInfo.processIdentifier)
        let windowCount = runningApp.map { self.getWindowCount(for: $0) } ?? 0

        appInfo.windowCount = windowCount
        return appInfo
    }
}
