import AppKit
import Foundation
import PeekabooFoundation

@MainActor
extension ApplicationService {
    public func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData> {
        let startTime = Date()
        self.logger.info("Listing all running applications")

        // Already on main thread due to @MainActor on class
        let runningApps = NSWorkspace.shared.runningApplications

        self.logger.debug("Found \(runningApps.count) running processes")

        // Filter apps first with defensive checks
        let appsToProcess = runningApps.compactMap { app -> NSRunningApplication? in
            // Defensive check - ensure app is valid
            guard !app.isTerminated else { return nil }

            // Skip apps without a localized name
            guard app.localizedName != nil else { return nil }

            // Skip system/background apps
            if app.activationPolicy == .prohibited {
                return nil
            }

            return app
        }

        // Now create app info with window counts
        let filteredApps = appsToProcess.compactMap { app -> ServiceApplicationInfo? in
            // Defensive check in case app terminated while processing
            guard !app.isTerminated else { return nil }
            return self.createApplicationInfo(from: app)
        }.sorted { app1, app2 -> Bool in
            return app1.name < app2.name
        }

        self.logger.info("Returning \(filteredApps.count) visible applications")

        // Find active app and calculate counts
        let activeApp = filteredApps.first { $0.isActive }
        let appsWithWindows = filteredApps.filter { $0.windowCount > 0 }
        let totalWindows = filteredApps.reduce(0) { $0 + $1.windowCount }

        // Build highlights
        var highlights: [UnifiedToolOutput<ServiceApplicationListData>.Summary.Highlight] = []
        if let active = activeApp {
            highlights.append(.init(
                label: active.name,
                value: "\(active.windowCount) window\(active.windowCount == 1 ? "" : "s")",
                kind: .primary))
        }

        return UnifiedToolOutput(
            data: ServiceApplicationListData(applications: filteredApps),
            summary: UnifiedToolOutput.Summary(
                brief: "Found \(filteredApps.count) running application\(filteredApps.count == 1 ? "" : "s")",
                detail: nil,
                status: .success,
                counts: [
                    "applications": filteredApps.count,
                    "appsWithWindows": appsWithWindows.count,
                    "totalWindows": totalWindows,
                ],
                highlights: highlights),
            metadata: UnifiedToolOutput.Metadata(
                duration: Date().timeIntervalSince(startTime),
                warnings: [],
                hints: ["Use app name or PID to target specific application"]))
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
        ServiceApplicationInfo(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            name: app.localizedName ?? "Unknown",
            bundlePath: app.bundleURL?.path,
            isActive: app.isActive,
            isHidden: app.isHidden,
            windowCount: self.getWindowCount(for: app),
            activationPolicy: Self.serviceActivationPolicy(from: app.activationPolicy),
            isFinishedLaunching: app.isFinishedLaunching)
    }

    private static func serviceActivationPolicy(
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
        let cgWindows = self.windowIdentityService.getWindows(for: app)
        if cgWindows.isEmpty {
            return 0
        }

        let renderable = cgWindows.filter(\.isRenderable)
        return renderable.isEmpty ? cgWindows.count : renderable.count
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
