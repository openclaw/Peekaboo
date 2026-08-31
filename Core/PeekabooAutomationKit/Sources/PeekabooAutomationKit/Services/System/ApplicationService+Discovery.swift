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
    case overloaded
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
    public func applicationMutationInventory() async throws
        -> DesktopTargetPlanning.Inventory<ServiceApplicationInfo>
    {
        let processIdentifiers = Array(Set(self.runningApplicationProcessIdentifiersProvider()))
            .filter { $0 > 0 }
            .sorted()
        var applications: [ServiceApplicationInfo] = []
        var warnings: [String] = []
        for processIdentifier in processIdentifiers {
            guard let generation = self.processStartIdentityProvider(processIdentifier),
                  generation > 0
            else {
                warnings.append(
                    "Application PID \(processIdentifier) lacked process-generation identity and was omitted.")
                continue
            }
            guard let candidate = self.applicationMutationCandidateProvider(processIdentifier) else {
                warnings.append(
                    "Application PID \(processIdentifier) metadata was unavailable and was omitted.")
                continue
            }
            guard candidate.processIdentifier == processIdentifier,
                  self.processStartIdentityProvider(processIdentifier) == generation
            else {
                warnings.append(
                    "Application PID \(processIdentifier) changed process generation during inventory and was omitted.")
                continue
            }
            guard !candidate.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                warnings.append(
                    "Application PID \(processIdentifier) metadata lacked a usable name and was omitted.")
                continue
            }
            let activationPolicy: ServiceApplicationActivationPolicy = if !candidate.allowsFuzzyMatching {
                .prohibited
            } else if candidate.isRegularApplication {
                .regular
            } else {
                .accessory
            }
            applications.append(ServiceApplicationInfo(
                processIdentifier: processIdentifier,
                processStartIdentity: generation,
                bundleIdentifier: candidate.bundleIdentifier,
                name: candidate.name,
                bundlePath: candidate.bundlePath,
                executablePath: candidate.executablePath,
                activationPolicy: activationPolicy))
        }
        return DesktopTargetPlanning.Inventory(
            items: applications,
            completeness: warnings.isEmpty ? .complete : .partial,
            warnings: warnings)
    }

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

        var applications: [ServiceApplicationInfo] = []
        var omissionWarnings: [String] = []
        for read in reads {
            if let expectedGeneration = read.candidate.processStartIdentity,
               self.processStartIdentityProvider(read.candidate.processIdentifier) != expectedGeneration
            {
                omissionWarnings.append(
                    "Application PID \(read.candidate.processIdentifier) changed process generation during inventory " +
                        "and was omitted.")
                continue
            }
            if let application = self.applicationInfo(from: read) {
                applications.append(application)
            } else {
                omissionWarnings.append(Self.applicationOmissionWarning(read))
            }
        }
        applications.sort { app1, app2 -> Bool in
            app1.name == app2.name
                ? app1.processIdentifier < app2.processIdentifier
                : app1.name < app2.name
        }
        let warnings = Array(Set(Self.uniqueWarnings(in: applications) + omissionWarnings)).sorted()

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
                    "incompleteApplications":
                        applications.count(where: { !($0.metadataWarnings ?? []).isEmpty }),
                    "omittedApplications": omissionWarnings.count,
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
        if candidate.processStartIdentity == nil {
            warnings.append(
                "Process-generation identity was unavailable for PID \(candidate.processIdentifier)")
        }

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
        case .overloaded:
            guard candidate.processStartIdentity != nil else { return nil }
            warnings.append(
                "Application metadata capacity was exhausted for PID \(candidate.processIdentifier); " +
                    "hidden state and activation policy are unknown")
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
        } catch ApplicationMetadataAdmissionError.overloaded {
            return ApplicationInventoryRead(candidate: candidate, outcome: .overloaded)
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

    private static func applicationOmissionWarning(_ read: ApplicationInventoryRead) -> String {
        let pid = read.candidate.processIdentifier
        guard read.candidate.processStartIdentity != nil else {
            return "Application PID \(pid) lacked process-generation identity and was omitted."
        }
        switch read.outcome {
        case .processChanged:
            return "Application PID \(pid) changed process generation during metadata discovery and was omitted."
        case let .metadata(metadata) where metadata.name?.isEmpty != false:
            return "Application PID \(pid) metadata lacked a usable name and was omitted."
        default:
            return "Application PID \(pid) could not be represented in the inventory and was omitted."
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

        let runningApps = NSWorkspace.shared.runningApplications.filter { app in
            !app.isTerminated
        }
        let candidates = runningApps.map(Self.identifierCandidate)
        if let resolution = try ApplicationIdentifierMatcher.resolution(for: identifier, in: candidates) {
            guard !resolution.hasWinningTie else {
                throw PeekabooError.ambiguousAppIdentifier(
                    identifier,
                    suggestions: candidates.map(\.name))
            }
            let application = self.createApplicationInfo(from: runningApps[resolution.index])
            let proof = application.processIdentity.map {
                resolution.proof(selectedProcessIdentity: $0)
            }
            return application.withSelectorResolutionProofs(proof.map { [$0] })
        }

        self.logger.error("Application not found: \(identifier, privacy: .public)")
        throw PeekabooError.appNotFound(identifier)
    }

    static func identifierCandidate(_ app: NSRunningApplication) -> ApplicationIdentifierMatcher.Candidate {
        .init(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
            bundlePath: app.bundleURL?.path,
            executablePath: app.executableURL?.path,
            allowsFuzzyMatching: app.activationPolicy != .prohibited,
            isRegularApplication: app.activationPolicy == .regular)
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
            executablePath: app.executableURL?.path,
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
