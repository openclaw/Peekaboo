import AppKit
import AXorcist
import Foundation
import os.log
import PeekabooFoundation

@MainActor
extension ApplicationService {
    struct PreparedApplicationLaunch {
        let applicationURL: URL?
        let openURLs: [URL]
        let activates: Bool
        let waitUntilReady: Bool
        let disablesRunningApplicationSubstitution: Bool
    }

    public func launchApplication(identifier: String) async throws -> ServiceApplicationInfo {
        let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        self.logger.info("Launching application: \(trimmedIdentifier)")

        do {
            let existingApplication = try await self.findApplication(identifier: trimmedIdentifier)
            self.logger.debug("Application already running: \(existingApplication.name)")
            return existingApplication
        } catch {
            self.logger.debug("Application not currently running: \(trimmedIdentifier), will try to launch")
        }

        return try await self.launchApplication(request: ApplicationLaunchRequest(applicationIdentifier: identifier))
    }

    public func launchApplication(request: ApplicationLaunchRequest) async throws -> ServiceApplicationInfo {
        let identifier = request.applicationIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleIdentifier = request.applicationBundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.logger.info("Launching application: \(bundleIdentifier ?? identifier ?? "default handler")")

        let preparedLaunch = try self.prepareApplicationLaunch(request)
        return try await self.performApplicationLaunch(preparedLaunch)
    }

    func prepareApplicationLaunch(_ request: ApplicationLaunchRequest) throws -> PreparedApplicationLaunch {
        let identifier = request.applicationIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleIdentifier = request.applicationBundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if request.applicationIdentifier != nil, identifier?.isEmpty != false {
            throw PeekabooError.invalidInput("Application identifier must not be empty")
        }
        if request.applicationBundleIdentifier != nil, bundleIdentifier?.isEmpty != false {
            throw PeekabooError.invalidInput("Application bundle identifier must not be empty")
        }
        guard !(identifier?.isEmpty == false && bundleIdentifier?.isEmpty == false) else {
            throw PeekabooError.invalidInput(
                "Application launch accepts either an application identifier or bundle identifier, not both")
        }
        guard identifier?.isEmpty == false || bundleIdentifier?.isEmpty == false || !request.openURLs.isEmpty else {
            throw PeekabooError.invalidInput("Application launch requires an identifier or URL")
        }

        let applicationURL: URL? = if let bundleIdentifier, !bundleIdentifier.isEmpty {
            try self.resolveApplicationURL(bundleIdentifier: bundleIdentifier)
        } else {
            try identifier.flatMap { identifier in
                identifier.isEmpty ? nil : try self.resolveApplicationURL(identifier)
            }
        }
        if applicationURL == nil, request.openURLs.count != 1 {
            throw PeekabooError.invalidInput("Opening multiple URLs requires an application identifier")
        }

        return PreparedApplicationLaunch(
            applicationURL: applicationURL,
            openURLs: request.openURLs,
            activates: request.activates,
            waitUntilReady: request.waitUntilReady,
            disablesRunningApplicationSubstitution: identifier.map(Self.isExplicitApplicationPath) == true)
    }

    private func performApplicationLaunch(_ launch: PreparedApplicationLaunch) async throws -> ServiceApplicationInfo {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = launch.activates

        let runningApp: NSRunningApplication
        if let applicationURL = launch.applicationURL {
            if launch.disablesRunningApplicationSubstitution {
                config.allowsRunningApplicationSubstitution = false
            }
            self.logger.debug("Launching app from URL: \(applicationURL.path)")

            if launch.activates {
                let appName = applicationURL.deletingPathExtension().lastPathComponent
                let iconPath = applicationURL.appendingPathComponent("Contents/Resources/AppIcon.icns").path
                let hasIcon = FileManager.default.fileExists(atPath: iconPath)
                _ = await self.feedbackClient.showAppLaunch(appName: appName, iconPath: hasIcon ? iconPath : nil)
            }

            runningApp = try await self.applicationOpenHandler(applicationURL, launch.openURLs, config)
        } else {
            let targetURL = launch.openURLs[0]
            runningApp = try await NSWorkspace.shared.open(targetURL, configuration: config)
        }

        if launch.activates, !runningApp.isActive, !runningApp.activate(options: []) {
            self.logger.warning("Launch succeeded but failed to activate \(runningApp.localizedName ?? "application")")
        }

        try await self.waitUntilReadyIfNeeded(runningApp, requested: launch.waitUntilReady)
        try await self.waitUntilActiveIfNeeded(runningApp, requested: launch.activates)

        let launchMessage =
            "Successfully launched: \(runningApp.localizedName ?? "Unknown") (PID: \(runningApp.processIdentifier))"
        self.logger.info("\(launchMessage)")
        return self.createApplicationInfo(from: runningApp)
    }

    public func relaunchApplication(request: ApplicationRelaunchRequest) async throws -> ServiceApplicationInfo {
        guard request.waitSeconds.isFinite, request.waitSeconds >= 0 else {
            throw PeekabooError.invalidInput("Relaunch wait must be a finite, non-negative number of seconds")
        }

        // Resolve every launch prerequisite before mutating the target application.
        let preparedLaunch = try self.prepareApplicationLaunch(request.launchRequest)
        let target = try await self.resolveRelaunchTarget(request.targetIdentifier)
        if target.processIdentifier == getpid() {
            throw PeekabooError.serviceUnavailable("A runtime host cannot relaunch itself")
        }
        let canonicalTargetIdentifier = "PID:\(target.processIdentifier)"

        guard try await self.quitRelaunchTarget(
            identifier: canonicalTargetIdentifier,
            force: request.force)
        else {
            throw PeekabooError.commandFailed("Application refused to quit")
        }

        let terminationDeadline = Date().addingTimeInterval(5)
        while await self.isRelaunchTargetRunning(identifier: canonicalTargetIdentifier) {
            guard Date() < terminationDeadline else {
                throw PeekabooError.timeout("Application did not terminate within 5 seconds")
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        if request.waitSeconds > 0 {
            try await Task.sleep(for: .seconds(request.waitSeconds))
        }
        return try await self.performApplicationLaunch(preparedLaunch)
    }

    private func resolveRelaunchTarget(_ identifier: String) async throws -> ServiceApplicationInfo {
        if let relaunchTargetResolver = self.relaunchTargetResolver {
            return try await relaunchTargetResolver(identifier)
        }
        return try await self.findApplication(identifier: identifier)
    }

    private func quitRelaunchTarget(identifier: String, force: Bool) async throws -> Bool {
        if let relaunchQuitHandler = self.relaunchQuitHandler {
            return try await relaunchQuitHandler(identifier, force)
        }
        return try await self.quitApplication(identifier: identifier, force: force)
    }

    private func isRelaunchTargetRunning(identifier: String) async -> Bool {
        if let relaunchRunningHandler = self.relaunchRunningHandler {
            return await relaunchRunningHandler(identifier)
        }
        return await self.isApplicationRunning(identifier: identifier)
    }

    func resolveApplicationURL(_ identifier: String) throws -> URL {
        let expanded = NSString(string: identifier).expandingTildeInPath
        if identifier.contains("/"), FileManager.default.fileExists(atPath: expanded) {
            return URL(fileURLWithPath: expanded)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            self.logger.debug("Found app by bundle ID at: \(url.path)")
            return url
        }
        if let url = self.findApplicationByName(identifier) {
            self.logger.debug("Found app by name at: \(url.path)")
            return url
        }
        self.logger.error("Application not found in system: \(identifier)")
        throw PeekabooError.appNotFound(identifier)
    }

    func resolveApplicationURL(bundleIdentifier: String) throws -> URL {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            self.logger.error("Application bundle identifier not found: \(bundleIdentifier)")
            throw PeekabooError.appNotFound(bundleIdentifier)
        }
        self.logger.debug("Found app by bundle ID at: \(url.path)")
        return url
    }

    private static func isExplicitApplicationPath(_ identifier: String) -> Bool {
        let expanded = NSString(string: identifier).expandingTildeInPath
        return identifier.contains("/") && FileManager.default.fileExists(atPath: expanded)
    }

    private func waitUntilReadyIfNeeded(_ app: NSRunningApplication, requested: Bool) async throws {
        guard requested else { return }
        let deadline = Date().addingTimeInterval(10)
        while !app.isFinishedLaunching {
            guard Date() < deadline else {
                throw PeekabooError.timeout("Application did not become ready within 10 seconds")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func waitUntilActiveIfNeeded(_ app: NSRunningApplication, requested: Bool) async throws {
        guard requested else { return }
        let deadline = Date().addingTimeInterval(2)
        while !app.isActive, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    public func activateApplication(identifier: String) async throws {
        self.logger.info("Activating application: \(identifier)")
        let app = try await findApplication(identifier: identifier)

        // Create NSRunningApplication
        let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier)
        guard let runningApp else {
            throw PeekabooError.operationError(
                message: "Failed to activate application: Could not find running application process")
        }

        let activated = runningApp.activate(options: [])

        if !activated {
            self.logger.error("Failed to activate application: \(app.name). Continuing without activation.")
            return
        }

        self.logger.info("Successfully activated: \(app.name)")
        // Wait for activation to complete
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
    }

    public func quitApplication(identifier: String, force: Bool = false) async throws -> Bool {
        self.logger.info("Quitting application: \(identifier) (force: \(force))")
        let app = try await findApplication(identifier: identifier)

        // Create NSRunningApplication
        let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier)
        guard let runningApp else {
            throw PeekabooError.appNotFound(identifier)
        }

        // Try to get app icon path for animation
        var iconPath: String?
        if let bundleURL = runningApp.bundleURL {
            let potentialIconPath = bundleURL.appendingPathComponent("Contents/Resources/AppIcon.icns").path
            if FileManager.default.fileExists(atPath: potentialIconPath) {
                iconPath = potentialIconPath
            }
        }

        // Show app quit animation
        _ = await self.feedbackClient.showAppQuit(appName: app.name, iconPath: iconPath)

        self.logger.debug("Sending \(force ? "force terminate" : "terminate") signal to \(app.name)")
        let success = force ? runningApp.forceTerminate() : runningApp.terminate()

        // Wait a bit for the termination to complete
        if success {
            self.logger.info("Successfully quit: \(app.name)")
            try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
        } else {
            self.logger.error("Failed to quit: \(app.name)")
        }

        return success
    }

    public func hideApplication(identifier: String) async throws {
        self.logger.info("Hiding application: \(identifier)")
        let app = try await findApplication(identifier: identifier)

        guard let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier) else {
            throw NotFoundError.application(identifier)
        }
        let appElement = AXApp(runningApp).element

        do {
            try appElement.performAction(Attribute<String>("AXHide"))
            self.logger.debug("Hidden via AX action: \(app.name)")
        } catch {
            // Log the error but use fallback
            _ = error.asPeekabooError(context: "AX hide action failed for \(app.name)")
            // Fallback to NSRunningApplication method
            self.logger.debug("Using NSRunningApplication fallback")
            let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier)
            if let runningApp {
                runningApp.hide()
                self.logger.debug("Hidden via NSRunningApplication: \(app.name)")
            }
        }
    }

    public func unhideApplication(identifier: String) async throws {
        self.logger.info("Unhiding application: \(identifier)")
        let app = try await findApplication(identifier: identifier)

        guard let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier) else {
            throw NotFoundError.application(identifier)
        }
        let requestSent = runningApp.unhide()
        let deadline = Date().addingTimeInterval(1)
        repeat {
            // NSRunningApplication state is cached until the next main run-loop turn.
            try await Task.sleep(for: .milliseconds(50))
            guard runningApp.isHidden else {
                self.logger.debug("Unhidden application without activation: \(app.name)")
                return
            }
        } while Date() < deadline

        if requestSent {
            throw PeekabooError.operationError(message: "Application remained hidden: \(app.name)")
        }
        throw PeekabooError.operationError(message: "Failed to request unhide for application: \(app.name)")
    }

    public func hideOtherApplications(identifier: String) async throws {
        self.logger.info("Hiding other applications except: \(identifier)")
        let app = try await findApplication(identifier: identifier)

        guard let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier) else {
            throw NotFoundError.application(identifier)
        }
        let appElement = AXApp(runningApp).element

        do {
            // Use custom attribute for hide others action
            try appElement.performAction(Attribute<String>("AXHideOthers"))
            self.logger.debug("Hidden others via AX action")
        } catch {
            // Log the error but use fallback
            _ = error.asPeekabooError(context: "AX hide others action failed")
            // Fallback: hide each app individually
            self.logger.debug("Hiding apps individually")
            // Already on main thread due to @MainActor on class
            let apps = NSWorkspace.shared.runningApplications
            var hiddenCount = 0
            for runningApp in apps {
                if runningApp.processIdentifier != app.processIdentifier,
                   runningApp.activationPolicy == .regular,
                   runningApp.bundleIdentifier != "com.apple.finder"
                {
                    runningApp.hide()
                    hiddenCount += 1
                }
            }
            // Return value already computed
            self.logger.debug("Hidden \(hiddenCount) other applications")
        }
    }

    public func showAllApplications() async throws {
        self.logger.info("Showing all applications")
        let systemWide = Element.systemWide()

        do {
            // Use custom attribute for show all action
            try systemWide.performAction(Attribute<String>("AXShowAll"))
            self.logger.debug("Shown all via AX action")
        } catch {
            // Log the error but use fallback
            _ = error.asPeekabooError(context: "AX show all action failed")
            // Fallback: unhide each hidden app
            self.logger.debug("Unhiding apps individually")
            // Already on main thread due to @MainActor on class
            let apps = NSWorkspace.shared.runningApplications
            var unhiddenCount = 0
            for runningApp in apps {
                if runningApp.isHidden, runningApp.activationPolicy == .regular {
                    runningApp.unhide()
                    unhiddenCount += 1
                }
            }
            // Return value already computed
            self.logger.debug("Unhidden \(unhiddenCount) applications")
        }
    }

    private func findApplicationByName(_ name: String) -> URL? {
        self.logger.debug("Searching for application by name: \(name)")

        // First, try exact name in common directories
        let searchPaths = [
            "/Applications",
            "/System/Applications",
            "/System/Library/CoreServices",
            "/Applications/Utilities",
            "~/Applications",
        ].map { NSString(string: $0).expandingTildeInPath }

        let fileManager = FileManager.default

        for path in searchPaths {
            let searchName = name.hasSuffix(".app") ? name : "\(name).app"
            let fullPath = (path as NSString).appendingPathComponent(searchName)

            if fileManager.fileExists(atPath: fullPath) {
                self.logger.debug("Found app at: \(fullPath)")
                return URL(fileURLWithPath: fullPath)
            }
        }

        // Try NSWorkspace API with bundle ID
        // Already on main thread due to @MainActor on class
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
            self.logger.debug("Found app via bundle identifier: \(url.path)")
            return url
        }

        // Use Spotlight search for more flexible app discovery
        if let url = searchApplicationWithSpotlight(name) {
            self.logger.debug("Found app via Spotlight: \(url.path)")
            return url
        }

        self.logger.debug("Application not found by name: \(name)")
        return nil
    }

    @MainActor
    private func searchApplicationWithSpotlight(_ name: String) -> URL? {
        SpotlightApplicationSearcher(logger: self.logger, name: name).search()
    }
}

@MainActor
private struct SpotlightApplicationSearcher {
    let logger: Logger
    let name: String

    func search() -> URL? {
        self.logger.debug("Using Spotlight to search for: \(self.name)")
        let query = self.makeQuery()
        query.start()
        self.waitForResults(query)
        query.stop()
        self.logger.debug("Spotlight query completed with \(query.resultCount) results")

        guard let match = bestMatch(in: query) else {
            return nil
        }

        let resultMessage = "Spotlight found app: \(match.url.path) (score: \(match.score))"
        self.logger.debug("\(resultMessage)")
        return match.url
    }

    private func makeQuery() -> NSMetadataQuery {
        let query = NSMetadataQuery()
        let predicateFormat =
            "(kMDItemContentType == 'com.apple.application-bundle' || kMDItemContentType == 'com.apple.application')" +
            " && (kMDItemDisplayName CONTAINS[cd] %@ || kMDItemFSName CONTAINS[cd] %@)"
        query.predicate = NSPredicate(format: predicateFormat, self.name, self.name)
        query.searchScopes = [
            NSMetadataQueryIndexedLocalComputerScope,
            NSMetadataQueryIndexedNetworkScope,
        ]
        return query
    }

    private func waitForResults(_ query: NSMetadataQuery) {
        let startTime = Date()
        while query.isGathering, Date().timeIntervalSince(startTime) < 2.0 {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
    }

    private func bestMatch(in query: NSMetadataQuery) -> (url: URL, score: Int)? {
        var bestMatch: (url: URL, score: Int)?
        let searchTerm = self.name.lowercased()

        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else {
                continue
            }

            let appURL = URL(fileURLWithPath: path)
            let displayName = (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String) ?? ""
            let fsName = appURL.lastPathComponent

            let spotlightMessage =
                "Spotlight found: \(path), displayName: '\(displayName)', fsName: '\(fsName)'"
            self.logger.debug("\(spotlightMessage)")

            let score = score(for: displayName, fsName: fsName, path: path, searchTerm: searchTerm)
            if score > (bestMatch?.score ?? 0) {
                bestMatch = (appURL, score)
            }

            if score >= 100 {
                break
            }
        }

        return bestMatch
    }

    private func score(
        for displayName: String,
        fsName: String,
        path: String,
        searchTerm: String) -> Int
    {
        var score = 0
        let fsNameNoExt = fsName.hasSuffix(".app") ? String(fsName.dropLast(4)) : fsName
        let displayLower = displayName.lowercased()
        let fsLower = fsNameNoExt.lowercased()

        if displayLower == searchTerm ||
            fsLower == searchTerm ||
            fsName.lowercased() == "\(searchTerm).app"
        {
            score = 100
        } else if displayLower.hasPrefix(searchTerm) || fsLower.hasPrefix(searchTerm) {
            score = 80
        } else if displayLower.contains(searchTerm) || fsLower.contains(searchTerm) {
            score = 50
        }

        if path.hasPrefix("/Applications/") {
            score += 10
        } else if path.hasPrefix("/System/Applications/") {
            score += 5
        }

        if path.contains("/DerivedData/"), path.contains("/Debug/") {
            score += 15
        }

        return score
    }
}
