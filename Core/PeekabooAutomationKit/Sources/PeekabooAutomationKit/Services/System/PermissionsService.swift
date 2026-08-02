import ApplicationServices
import AXorcist
import CoreGraphics
import Foundation
import os.log
import PeekabooFoundation

/// Service for checking and managing macOS system permissions
@MainActor
public final class PermissionsService {
    struct Dependencies {
        let screenRecordingPreflight: @MainActor @Sendable () -> Bool
        let screenRecordingRequest: @MainActor @Sendable () -> Bool
        let screenRecordingEvaluator: any ScreenRecordingPermissionEvaluating
        let postEventPreflight: @MainActor @Sendable () -> Bool
        let postEventRequest: @MainActor @Sendable () -> Bool

        @MainActor
        static func live() -> Dependencies {
            Dependencies(
                screenRecordingPreflight: { CGPreflightScreenCaptureAccess() },
                screenRecordingRequest: {
                    guard !PermissionsService.isRunningUnderTests else {
                        return CGPreflightScreenCaptureAccess()
                    }
                    return CGRequestScreenCaptureAccess()
                },
                screenRecordingEvaluator: ScreenRecordingPermissionChecker(),
                postEventPreflight: { CGPreflightPostEventAccess() },
                postEventRequest: {
                    guard !PermissionsService.isRunningUnderTests else {
                        return CGPreflightPostEventAccess()
                    }
                    return CGRequestPostEventAccess()
                })
        }
    }

    @MainActor
    final class AuthorizationState {
        static let process = AuthorizationState()

        private(set) var screenRecordingAuthorized = false
        private(set) var screenRecordingProbeUnlocked = false
        private(set) var postEventAuthorized = false

        private var screenRecordingProbeTask: Task<Bool, Never>?
        private var screenRecordingProbeGeneration = 0
        private var lastScreenRecordingProbeAt: ContinuousClock.Instant?

        func recordScreenRecordingAuthorization(_ authorized: Bool) -> Bool {
            self.screenRecordingAuthorized = self.screenRecordingAuthorized || authorized
            return self.screenRecordingAuthorized
        }

        func unlockScreenRecordingProbe() {
            self.screenRecordingProbeUnlocked = true
        }

        func recordPostEventAuthorization(_ authorized: Bool) -> Bool {
            self.postEventAuthorized = self.postEventAuthorized || authorized
            return self.postEventAuthorized
        }

        func evaluateScreenRecordingAuthorization(
            using evaluator: any ScreenRecordingPermissionEvaluating,
            logger: CategoryLogger,
            minimumProbeInterval: Duration,
            bypassRateLimit: Bool = false) async -> Bool
        {
            if self.screenRecordingAuthorized {
                return true
            }

            if let joinedProbeTask = screenRecordingProbeTask {
                let joined = self.recordScreenRecordingAuthorization(await joinedProbeTask.value)
                // Waiters can resume in any order, so every joiner clears the completed task if
                // it is still the one it awaited; otherwise a forced call below could re-join the
                // same stale probe instead of starting a fresh one.
                if self.screenRecordingProbeTask == joinedProbeTask {
                    self.screenRecordingProbeTask = nil
                }
                // A forced check must not settle for a probe that may predate the grant it is
                // trying to observe; fall through to a fresh probe unless the joined one succeeded.
                if joined || !bypassRateLimit {
                    return joined
                }
                if let restartedProbeTask = self.screenRecordingProbeTask {
                    return await self.recordScreenRecordingAuthorization(restartedProbeTask.value)
                }
            }

            let now = ContinuousClock.now
            if !bypassRateLimit,
               let lastScreenRecordingProbeAt,
               now - lastScreenRecordingProbeAt < minimumProbeInterval
            {
                return false
            }

            self.lastScreenRecordingProbeAt = now
            self.screenRecordingProbeGeneration += 1
            let generation = self.screenRecordingProbeGeneration
            let task = Task { @MainActor in
                await evaluator.hasPermission(logger: logger)
            }
            self.screenRecordingProbeTask = task

            let authorized = await task.value
            if self.screenRecordingProbeGeneration == generation {
                self.screenRecordingProbeTask = nil
            }
            return self.recordScreenRecordingAuthorization(authorized)
        }
    }

    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "PermissionsService")
    private let permissionLogger: CategoryLogger
    private let dependencies: Dependencies
    private let authorizationState: AuthorizationState
    private let screenRecordingProbeMinimumInterval: Duration

    public convenience init() {
        self.init(dependencies: .live(), authorizationState: .process)
    }

    init(
        dependencies: Dependencies,
        authorizationState: AuthorizationState = AuthorizationState(),
        screenRecordingProbeMinimumInterval: Duration = .milliseconds(1500),
        loggingService: any LoggingServiceProtocol = LoggingService())
    {
        self.dependencies = dependencies
        self.authorizationState = authorizationState
        self.screenRecordingProbeMinimumInterval = screenRecordingProbeMinimumInterval
        self.permissionLogger = loggingService.logger(category: LoggingService.Category.permissions)
    }

    private static var isRunningUnderTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            ProcessInfo.processInfo.arguments.contains("--test-mode") ||
            NSClassFromString("XCTest") != nil
    }

    /// Check if Screen Recording permission is granted using the cheap synchronous preflight.
    ///
    /// UI polling should use `checkScreenRecordingPermissionLive()` so a grant made while the
    /// process is running can be observed through ScreenCaptureKit.
    public func checkScreenRecordingPermission() -> Bool {
        self.logger.debug("Checking screen recording permission")

        if #available(macOS 10.15, *) {
            let hasPermission = self.authorizationState.recordScreenRecordingAuthorization(
                self.dependencies.screenRecordingPreflight())
            self.logger.info("Screen recording permission: \(hasPermission)")
            return hasPermission
        }

        return self.authorizationState.recordScreenRecordingAuthorization(true)
    }

    /// Check Screen Recording permission using the shared preflight-or-ScreenCaptureKit probe.
    ///
    /// Failed preflights are rate-limited because the fallback is an XPC round-trip. Successful
    /// authoritative results remain sticky for the lifetime of the process because CoreGraphics
    /// can keep returning a cached denial after the user grants access in System Settings.
    public func checkScreenRecordingPermissionLive(forceProbe: Bool = false) async -> Bool {
        self.logger.debug("Checking live screen recording permission")

        if forceProbe {
            self.authorizationState.unlockScreenRecordingProbe()
        }

        let preflightAuthorized = self.checkScreenRecordingPermission()
        guard !preflightAuthorized else { return true }
        guard self.authorizationState.screenRecordingProbeUnlocked else { return false }

        return await self.authorizationState.evaluateScreenRecordingAuthorization(
            using: self.dependencies.screenRecordingEvaluator,
            logger: self.permissionLogger,
            minimumProbeInterval: self.screenRecordingProbeMinimumInterval,
            bypassRateLimit: forceProbe)
    }

    @discardableResult
    public func requestScreenRecordingPermission(interactive: Bool = true) -> Bool {
        self.logger.debug("Requesting screen recording permission")

        guard interactive else { return self.checkScreenRecordingPermission() }
        self.authorizationState.unlockScreenRecordingProbe()
        guard #available(macOS 10.15, *) else {
            return self.authorizationState.recordScreenRecordingAuthorization(true)
        }

        let granted = self.dependencies.screenRecordingRequest()
        self.logger.info("Screen recording permission request returned: \(granted)")
        return self.authorizationState.recordScreenRecordingAuthorization(granted)
    }

    /// Check if Accessibility permission is granted
    public func checkAccessibilityPermission() -> Bool {
        self.logger.debug("Checking accessibility permission")

        // Check if we have accessibility permission through AXorcist helper
        let hasPermission = AXPermissionHelpers.hasAccessibilityPermissions()

        self.logger.info("Accessibility permission: \(hasPermission)")
        return hasPermission
    }

    /// Check if event-synthesizing permission is granted.
    public func checkPostEventPermission() -> Bool {
        self.logger.debug("Checking event-synthesizing permission")

        if #available(macOS 10.15, *) {
            // Settings-only grants cannot be detected while this process is running because
            // CGPreflightPostEventAccess is process-cached and no live probe API exists. Relaunch is required;
            // the interactive request path remains authoritative for grants made in-process.
            let hasPermission = self.authorizationState.recordPostEventAuthorization(
                self.dependencies.postEventPreflight())
            self.logger.info("Event-synthesizing permission: \(hasPermission)")
            return hasPermission
        }

        return self.authorizationState.recordPostEventAuthorization(true)
    }

    @discardableResult
    public func requestPostEventPermission(interactive: Bool = true) -> Bool {
        self.logger.debug("Requesting event-synthesizing permission")

        guard interactive else { return self.checkPostEventPermission() }
        guard #available(macOS 10.15, *) else {
            return self.authorizationState.recordPostEventAuthorization(true)
        }

        let granted = self.dependencies.postEventRequest()
        self.logger.info("Event-synthesizing permission request returned: \(granted)")
        return self.authorizationState.recordPostEventAuthorization(granted)
    }

    @discardableResult
    public func requestAccessibilityPermission(interactive: Bool = true) -> Bool {
        self.logger.debug("Requesting accessibility permission")

        guard interactive else { return self.checkAccessibilityPermission() }
        let hasPermission = AXPermissionHelpers.askForAccessibilityIfNeeded()
        self.logger.info("Accessibility permission (after request): \(hasPermission)")
        return hasPermission
    }

    /// Check if AppleScript permission is granted
    public func checkAppleScriptPermission() -> Bool {
        self.checkAppleScriptPermission(allowTargetLaunch: true)
    }

    private func checkAppleScriptPermission(allowTargetLaunch: Bool) -> Bool {
        self.logger.debug("Checking AppleScript permission")

        // Apple Events automation permission is evaluated against a target app.
        // We probe System Events since it's the most common automation target.
        let bundleIdentifier = "com.apple.systemevents"

        var permissionStatus = Self.determineAppleScriptAutomationPermissionStatus(
            targetBundleIdentifier: bundleIdentifier,
            askUser: false)

        if permissionStatus == procNotFound, allowTargetLaunch, !Self.isRunningUnderTests {
            self.logger.debug("AppleScript permission probe returned procNotFound; launching target and retrying")
            Self.launchApplication(bundleIdentifier: bundleIdentifier, logger: self.logger)
            permissionStatus = Self.determineAppleScriptAutomationPermissionStatus(
                targetBundleIdentifier: bundleIdentifier,
                askUser: false)
        }

        let hasPermission = permissionStatus == noErr
        self.logger.info("AppleScript permission status: \(permissionStatus), has permission: \(hasPermission)")
        return hasPermission
    }

    @discardableResult
    public func requestAppleScriptPermission(interactive: Bool = true) -> Bool {
        self.logger.debug("Requesting AppleScript permission")

        guard interactive else { return self.checkAppleScriptPermission() }
        if Self.isRunningUnderTests {
            return self.checkAppleScriptPermission()
        }

        let bundleIdentifier = "com.apple.systemevents"

        var permissionStatus = Self.determineAppleScriptAutomationPermissionStatus(
            targetBundleIdentifier: bundleIdentifier,
            askUser: true)

        if permissionStatus == procNotFound {
            self.logger.debug("AppleScript permission request returned procNotFound; launching target and retrying")
            Self.launchApplication(bundleIdentifier: bundleIdentifier, logger: self.logger)
            permissionStatus = Self.determineAppleScriptAutomationPermissionStatus(
                targetBundleIdentifier: bundleIdentifier,
                askUser: true)
        }

        let hasPermission = permissionStatus == noErr
        self.logger.info("AppleScript permission request status: \(permissionStatus), has permission: \(hasPermission)")
        return self.checkAppleScriptPermission()
    }

    private static func determineAppleScriptAutomationPermissionStatus(
        targetBundleIdentifier: String,
        askUser: Bool) -> OSStatus
    {
        guard var addressDesc = makeAppleEventTargetAddressDesc(bundleIdentifier: targetBundleIdentifier) else {
            return OSStatus(paramErr)
        }
        defer { AEDisposeDesc(&addressDesc) }

        // IMPORTANT:
        // Use an Apple Event that reflects *automation* (not just launching an app). `oapp` (open app)
        // can succeed even when automation is not authorized, and will not reliably trigger the TCC prompt.
        //
        // `core/getd` (get data) is a common, benign automation event that maps well to "tell app ... return ...".
        let eventClass = AEEventClass(0x636F_7265) // 'core'
        let eventID = AEEventID(0x6765_7464) // 'getd'

        return autoreleasepool {
            AEDeterminePermissionToAutomateTarget(&addressDesc, eventClass, eventID, askUser)
        }
    }

    static func makeAppleEventTargetAddressDesc(bundleIdentifier: String) -> AEDesc? {
        guard let bundleIDData = bundleIdentifier.data(using: .utf8), !bundleIDData.isEmpty else {
            return nil
        }

        var addressDesc = AEDesc()
        let status = bundleIDData.withUnsafeBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return OSStatus(paramErr) }
            return OSStatus(AECreateDesc(DescType(typeApplicationBundleID), baseAddress, buffer.count, &addressDesc))
        }
        guard status == noErr else { return nil }
        return addressDesc
    }

    private static func launchApplication(bundleIdentifier: String, logger: Logger) {
        guard !self.isRunningUnderTests else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-b", bundleIdentifier]

        do {
            try process.run()
        } catch {
            logger
                .debug(
                    """
                    Failed to launch app \(bundleIdentifier, privacy: .public): \
                    \(String(describing: error), privacy: .public)
                    """)
        }
    }

    /// Require Screen Recording permission, throwing if not granted
    public func requireScreenRecordingPermission() throws {
        // Require Screen Recording permission, throwing if not granted
        self.logger.debug("Requiring screen recording permission")

        if !self.checkScreenRecordingPermission() {
            self.logger.error("Screen recording permission denied")
            throw PeekabooError.permissionDeniedScreenRecording
        }
    }

    /// Require Accessibility permission, throwing if not granted
    public func requireAccessibilityPermission() throws {
        // Require Accessibility permission, throwing if not granted
        self.logger.debug("Requiring accessibility permission")

        if !self.checkAccessibilityPermission() {
            self.logger.error("Accessibility permission denied")
            throw PeekabooError.permissionDeniedAccessibility
        }
    }

    /// Require AppleScript permission, throwing if not granted
    public func requireAppleScriptPermission() throws {
        // Require AppleScript permission, throwing if not granted
        self.logger.debug("Requiring AppleScript permission")

        if !self.checkAppleScriptPermission() {
            self.logger.error("AppleScript permission denied")
            throw PeekabooError.operationError(message: "AppleScript permission denied")
        }
    }

    /// Check all permissions and return their status
    public func checkAllPermissions(allowAppleScriptLaunch: Bool = true) -> PermissionsStatus {
        // Check all permissions and return their status
        self.logger.debug("Checking all permissions")

        let screenRecording = self.checkScreenRecordingPermission()
        let accessibility = self.checkAccessibilityPermission()
        let appleScript = self.checkAppleScriptPermission(allowTargetLaunch: allowAppleScriptLaunch)
        let postEvent = self.checkPostEventPermission()

        return PermissionsStatus(
            screenRecording: screenRecording,
            accessibility: accessibility,
            appleScript: appleScript,
            postEvent: postEvent)
    }
}

/// Status of system permissions
public struct PermissionsStatus: Sendable, Codable {
    public let screenRecording: Bool
    public let accessibility: Bool
    public let appleScript: Bool
    public let postEvent: Bool

    public init(
        screenRecording: Bool,
        accessibility: Bool,
        appleScript: Bool = false,
        postEvent: Bool = false)
    {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.appleScript = appleScript
        self.postEvent = postEvent
    }

    public func withPostEvent(_ postEvent: Bool) -> PermissionsStatus {
        PermissionsStatus(
            screenRecording: self.screenRecording,
            accessibility: self.accessibility,
            appleScript: self.appleScript,
            postEvent: postEvent)
    }

    public var allGranted: Bool {
        self.screenRecording && self.accessibility
    }

    public var missingPermissions: [String] {
        var missing: [String] = []
        if !self.screenRecording {
            missing.append("Screen Recording")
        }
        if !self.accessibility {
            missing.append("Accessibility")
        }
        return missing
    }

    public var missingOptionalPermissions: [String] {
        var missing: [String] = []
        if !self.appleScript {
            missing.append("AppleScript")
        }
        if !self.postEvent {
            missing.append("Event Synthesizing")
        }
        return missing
    }

    private enum CodingKeys: String, CodingKey {
        case screenRecording
        case accessibility
        case appleScript
        case postEvent
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.screenRecording = try container.decode(Bool.self, forKey: .screenRecording)
        self.accessibility = try container.decode(Bool.self, forKey: .accessibility)
        self.appleScript = try container.decodeIfPresent(Bool.self, forKey: .appleScript) ?? false
        self.postEvent = try container.decodeIfPresent(Bool.self, forKey: .postEvent) ?? false
    }
}
