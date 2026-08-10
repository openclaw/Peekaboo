import CoreGraphics
import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

extension VerifyStateTool {
    @MainActor
    func verify(_ request: VerifyStateRequest) async throws -> ToolResponse {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let deadline = startedAt.advanced(by: .milliseconds(request.timeoutMilliseconds))
        let timing = VerifyStatePollTiming(clock: clock, startedAt: startedAt, deadline: deadline)
        let progress = VerifyStatePollProgress()
        let identityTracker = VerifyStateTargetIdentityTracker(
            target: request.target,
            windowBoundsRequirements: request.windowBoundsRequirements,
            processStartIdentityProvider: self.processStartIdentityProvider)

        do {
            return try await VerifyStateDeadlineRunner.run(
                seconds: TimeInterval(request.timeoutMilliseconds) / 1000)
            {
                try await self.verifyWithinDeadline(
                    request,
                    timing: timing,
                    progress: progress,
                    identityTracker: identityTracker)
            }
        } catch VerifyStateDeadlineError.timedOut {
            let progressSnapshot = await progress.snapshot()
            let observed = progressSnapshot.lastSample ?? Self.unknownSample(
                request: request,
                reason: "No state sample completed before the hard deadline")
            let terminal = Self.terminalSample(
                observed,
                stableCount: progressSnapshot.stableCount,
                requiredStableSamples: request.stableSamples,
                deadlineExpired: true)
            return await self.response(
                sample: terminal,
                request: request,
                context: VerifyStateResponseContext(
                    sampleCount: progressSnapshot.sampleCount,
                    stableCount: progressSnapshot.stableCount,
                    elapsedSeconds: Self.seconds(startedAt.duration(to: clock.now)),
                    identityTracker: identityTracker),
                screenshotDeadlineExpired: true)
        }
    }

    private func verifyWithinDeadline(
        _ request: VerifyStateRequest,
        timing: VerifyStatePollTiming,
        progress: VerifyStatePollProgress,
        identityTracker: VerifyStateTargetIdentityTracker) async throws -> ToolResponse
    {
        var nextPollAt = timing.startedAt
        var stableFingerprint: String?
        var stableCount = 0

        repeat {
            try Task.checkCancellation()
            let remainingSeconds = max(Self.seconds(timing.clock.now.duration(to: timing.deadline)), 0.05)
            let sample = await self.sample(
                request,
                remainingSeconds: remainingSeconds,
                identityTracker: identityTracker)
            // A sample proves state only at completion. Never let a result that crossed
            // the monotonic deadline contribute to stability or become the terminal sample.
            guard timing.clock.now <= timing.deadline else { break }
            await progress.record(sample)

            if sample.status == .satisfied {
                if stableFingerprint == sample.stabilityFingerprint {
                    stableCount += 1
                } else {
                    stableFingerprint = sample.stabilityFingerprint
                    stableCount = 1
                }
                await progress.updateStableCount(stableCount)

                if stableCount >= request.stableSamples, timing.clock.now <= timing.deadline {
                    let progressSnapshot = await progress.snapshot()
                    return await self.response(
                        sample: sample,
                        request: request,
                        context: VerifyStateResponseContext(
                            sampleCount: progressSnapshot.sampleCount,
                            stableCount: progressSnapshot.stableCount,
                            elapsedSeconds: Self.seconds(timing.startedAt.duration(to: timing.clock.now)),
                            identityTracker: identityTracker))
                }
            } else {
                stableFingerprint = nil
                stableCount = 0
                await progress.updateStableCount(0)
            }

            guard timing.clock.now < timing.deadline else { break }
            nextPollAt = nextPollAt.advanced(by: .milliseconds(VerifyStateRequest.pollIntervalMilliseconds))
            if nextPollAt < timing.clock.now {
                nextPollAt = timing.clock.now
            }
            let sleepUntil = min(nextPollAt, timing.deadline)
            try await timing.clock.sleep(until: sleepUntil)
        } while timing.clock.now <= timing.deadline

        let progressSnapshot = await progress.snapshot()
        let observed = progressSnapshot.lastSample ?? Self.unknownSample(
            request: request,
            reason: "No state sample completed before the deadline")
        let terminalSample = Self.terminalSample(
            observed,
            stableCount: progressSnapshot.stableCount,
            requiredStableSamples: request.stableSamples,
            deadlineExpired: false)

        return await self.response(
            sample: terminalSample,
            request: request,
            context: VerifyStateResponseContext(
                sampleCount: progressSnapshot.sampleCount,
                stableCount: progressSnapshot.stableCount,
                elapsedSeconds: Self.seconds(timing.startedAt.duration(to: timing.clock.now)),
                identityTracker: identityTracker))
    }

    private static func terminalSample(
        _ observed: VerifyStateSample,
        stableCount: Int,
        requiredStableSamples: Int,
        deadlineExpired: Bool) -> VerifyStateSample
    {
        guard observed.status == .satisfied, stableCount < requiredStableSamples else { return observed }
        let reason = deadlineExpired
            ? "Hard deadline expired before the requested stable sample count was established"
            : "Predicates matched, but the requested stable sample count was not established"
        return VerifyStateSample(
            status: .unknown,
            application: observed.application,
            window: observed.window,
            predicates: observed.predicates,
            reason: reason)
    }

    private func sample(
        _ request: VerifyStateRequest,
        remainingSeconds: TimeInterval,
        identityTracker: VerifyStateTargetIdentityTracker) async -> VerifyStateSample
    {
        let applicationResolution = await self.resolveApplication(request.target)
        switch applicationResolution {
        case let .missing(reason):
            if let identityFailure = await identityTracker.targetAbsenceFailure() {
                return Self.unknownSample(request: request, reason: identityFailure)
            }
            return Self.evaluateMissingTarget(request: request, reason: reason)
        case let .unknown(reason):
            return Self.unknownSample(request: request, reason: reason)
        case let .resolved(application):
            let resolvedApplication: VerifyStateResolvedApplication
            switch await identityTracker.resolve(application) {
            case let .resolved(resolved):
                resolvedApplication = resolved
            case let .unknown(reason):
                return Self.unknownSample(request: request, application: application, reason: reason)
            }
            let windowResolution = await self.resolveWindow(
                request: request,
                application: resolvedApplication,
                remainingSeconds: remainingSeconds,
                identityTracker: identityTracker)
            let window: ServiceWindowInfo
            switch windowResolution {
            case let .resolved(resolvedWindow):
                window = resolvedWindow
            case let .missing(reason):
                return Self.evaluateMissingTarget(
                    request: request,
                    application: application,
                    reason: reason)
            case let .unknown(reason):
                return Self.unknownSample(request: request, application: application, reason: reason)
            }

            guard request.needsAccessibilityTree else {
                return Self.evaluate(
                    request: request,
                    application: application,
                    window: window,
                    accessibilityEvidence: nil)
            }

            let context = WindowContext(
                applicationName: application.name,
                applicationBundleId: application.bundleIdentifier,
                applicationProcessId: application.processIdentifier,
                windowTitle: window.title,
                windowID: window.windowID,
                windowBounds: window.bounds,
                shouldFocusWebContent: false,
                includeMenuBarElements: false,
                traversalBudget: nil,
                requiresFreshAccessibilityTree: true,
                accessibilityTimeoutSeconds: min(max(remainingSeconds, 0.05), 10))
            do {
                let result = try await self.context.automation.inspectAccessibilityTree(windowContext: context)
                if let reason = await identityTracker.validate(resolvedApplication) {
                    return Self.unknownSample(request: request, application: application, reason: reason)
                }
                let completionWindowResolution = await self.resolveWindow(
                    request: request,
                    application: resolvedApplication,
                    remainingSeconds: remainingSeconds,
                    identityTracker: identityTracker)
                let completionWindow: ServiceWindowInfo
                switch completionWindowResolution {
                case let .resolved(resolvedWindow):
                    completionWindow = resolvedWindow
                case let .missing(reason), let .unknown(reason):
                    return Self.unknownSample(
                        request: request,
                        application: application,
                        reason: "Target window changed during accessibility inspection: \(reason)")
                }
                guard completionWindow.windowID == window.windowID,
                      completionWindow.bounds == window.bounds
                else {
                    return Self.unknownSample(
                        request: request,
                        application: application,
                        reason: "Target window identity or bounds changed during accessibility inspection")
                }
                if let reason = await identityTracker.validate(resolvedApplication) {
                    return Self.unknownSample(request: request, application: application, reason: reason)
                }
                let accessibilityEvidence = Self.accessibilityEvidence(
                    result,
                    application: application,
                    window: completionWindow)
                return Self.evaluate(
                    request: request,
                    application: application,
                    window: completionWindow,
                    accessibilityEvidence: accessibilityEvidence)
            } catch {
                if let reason = await identityTracker.validate(resolvedApplication) {
                    return Self.unknownSample(request: request, application: application, reason: reason)
                }
                return Self.evaluate(
                    request: request,
                    application: application,
                    window: window,
                    accessibilityEvidence: .unavailable(
                        "Accessibility inspection failed: \(error.localizedDescription)"))
            }
        }
    }

    private func resolveWindow(
        request: VerifyStateRequest,
        application: VerifyStateResolvedApplication,
        remainingSeconds: TimeInterval,
        identityTracker: VerifyStateTargetIdentityTracker) async -> WindowResolution
    {
        if let exactWindowID = request.windowID {
            guard let identity = self.windowIdentityProvider(exactWindowID) else {
                return await self.resolveExactWindowFromCompleteInventory(
                    exactWindowID,
                    application: application,
                    remainingSeconds: remainingSeconds,
                    identityTracker: identityTracker)
            }
            if let reason = await identityTracker.validateWindow(
                identity,
                application: application)
            {
                return .unknown(reason)
            }
            if let reason = await identityTracker.validate(application) {
                return .unknown(reason)
            }
            return .resolved(Self.serviceWindowInfo(identity))
        }

        do {
            let output = try await self.context.applications.listWindows(
                for: "PID:\(application.application.processIdentifier)",
                timeout: Float(min(max(remainingSeconds, 0.05), 10)))
            guard case .success = output.summary.status, output.metadata.warnings.isEmpty else {
                let warnings = output.metadata.warnings.isEmpty
                    ? output.summary.brief
                    : output.metadata.warnings.joined(separator: ", ")
                return .unknown("Window enumeration was incomplete: \(warnings)")
            }
            guard output.data.targetApplication?.processIdentifier == application.application.processIdentifier else {
                return .unknown("Window enumeration did not confirm target PID ownership")
            }
            if let reason = await identityTracker.validate(application) {
                return .unknown(reason)
            }
            guard let window = Self.selectWindow(output.data.windows, request: request) else {
                return .missing(Self.missingWindowReason(request))
            }
            guard let selectedWindowID = CGWindowID(exactly: window.windowID) else {
                return .unknown("Window enumeration returned invalid window ID \(window.windowID)")
            }
            guard let identity = self.windowIdentityProvider(selectedWindowID) else {
                return .unknown("CoreGraphics did not confirm ownership of window \(window.windowID)")
            }
            guard identity.ownerProcessIdentifier == application.application.processIdentifier else {
                return .unknown(
                    "Window \(window.windowID) belongs to PID \(identity.ownerProcessIdentifier), not target PID " +
                        "\(application.application.processIdentifier)")
            }
            if let reason = await identityTracker.validateWindow(identity, application: application) {
                return .unknown(reason)
            }
            if let reason = await identityTracker.validate(application) {
                return .unknown(reason)
            }
            return .resolved(Self.serviceWindowInfo(identity))
        } catch let error as PeekabooError {
            if case .appNotFound = error {
                switch await identityTracker.generationStatus(application) {
                case .gone:
                    return .missing("Target application exited")
                case let .unknown(reason):
                    return .unknown(reason)
                case .current:
                    return .unknown("Window enumeration omitted a still-running target process")
                }
            }
            return .unknown("Window enumeration failed: \(error.localizedDescription)")
        } catch {
            return .unknown("Window enumeration failed: \(error.localizedDescription)")
        }
    }

    private func resolveExactWindowFromCompleteInventory(
        _ exactWindowID: CGWindowID,
        application: VerifyStateResolvedApplication,
        remainingSeconds: TimeInterval,
        identityTracker: VerifyStateTargetIdentityTracker) async -> WindowResolution
    {
        switch await identityTracker.generationStatus(application) {
        case .gone:
            return .missing("Target application exited")
        case let .unknown(reason):
            return .unknown(reason)
        case .current:
            break
        }

        do {
            let output = try await self.context.applications.listWindows(
                for: "PID:\(application.application.processIdentifier)",
                timeout: Float(min(max(remainingSeconds, 0.05), 10)))
            guard case .success = output.summary.status, output.metadata.warnings.isEmpty else {
                let warnings = output.metadata.warnings.isEmpty
                    ? output.summary.brief
                    : output.metadata.warnings.joined(separator: ", ")
                return .unknown("Exact window inventory was incomplete: \(warnings)")
            }
            guard output.data.targetApplication?.processIdentifier == application.application.processIdentifier else {
                return .unknown("Exact window inventory did not confirm target PID ownership")
            }
            switch await identityTracker.generationStatus(application) {
            case .gone:
                return .missing("Target application exited")
            case let .unknown(reason):
                return .unknown(reason)
            case .current:
                break
            }
            if let window = output.data.windows.first(where: { $0.windowID == Int(exactWindowID) }) {
                if let reason = await identityTracker.validateWindow(window, application: application) {
                    return .unknown(reason)
                }
                return .resolved(window)
            }
            return .missing(
                "Window \(exactWindowID) is absent from the complete inventory for PID " +
                    "\(application.application.processIdentifier)")
        } catch let error as PeekabooError {
            if case .appNotFound = error {
                switch await identityTracker.generationStatus(application) {
                case .gone:
                    return .missing("Target application exited")
                case let .unknown(reason):
                    return .unknown(reason)
                case .current:
                    return .unknown("Exact window inventory omitted a still-running target process")
                }
            }
            return .unknown("Exact window inventory failed: \(error.localizedDescription)")
        } catch {
            return .unknown("Exact window inventory failed: \(error.localizedDescription)")
        }
    }

    private static func serviceWindowInfo(_ identity: SystemWindowIdentity) -> ServiceWindowInfo {
        ServiceWindowInfo(
            windowID: Int(identity.windowID),
            title: identity.title,
            bounds: identity.bounds,
            windowLevel: identity.layer,
            alpha: identity.alpha,
            isOffScreen: !identity.isOnScreen,
            layer: identity.layer,
            isOnScreen: identity.isOnScreen,
            sharingState: identity.sharingState)
    }

    private func resolveApplication(_ target: VerifyStateRequest.Target) async -> ApplicationResolution {
        switch target {
        case let .application(identifier):
            do {
                let output = try await self.context.applications.listApplications()
                guard case .success = output.summary.status, output.metadata.warnings.isEmpty else {
                    return .unknown(Self.incompleteApplicationListReason(output))
                }
                let applications = output.data.applications
                let exactMatches = applications.filter { application in
                    application.bundleIdentifier == identifier ||
                        application.name.compare(identifier, options: .caseInsensitive) == .orderedSame
                }
                switch exactMatches.count {
                case 0:
                    return .missing("Application '\(identifier)' is not running")
                case 1:
                    return .resolved(exactMatches[0])
                default:
                    return .unknown(
                        "Application '\(identifier)' has multiple exact process matches; use pid to disambiguate")
                }
            } catch {
                return .unknown("Application resolution failed: \(error.localizedDescription)")
            }
        case let .pid(pid):
            do {
                let output = try await self.context.applications.listApplications()
                guard case .success = output.summary.status, output.metadata.warnings.isEmpty else {
                    return .unknown(Self.incompleteApplicationListReason(output))
                }
                let applications = output.data.applications
                guard let application = applications.first(where: { $0.processIdentifier == pid }) else {
                    return .missing("PID \(pid) is not running")
                }
                return .resolved(application)
            } catch {
                return .unknown("PID resolution failed: \(error.localizedDescription)")
            }
        }
    }

    private static func incompleteApplicationListReason(
        _ output: UnifiedToolOutput<ServiceApplicationListData>) -> String
    {
        let detail = output.metadata.warnings.isEmpty
            ? output.summary.brief
            : output.metadata.warnings.joined(separator: ", ")
        return "Application enumeration was incomplete: \(detail)"
    }

    private static func selectWindow(
        _ windows: [ServiceWindowInfo],
        request: VerifyStateRequest) -> ServiceWindowInfo?
    {
        if let title = request.windowTitle {
            return windows.first(where: { $0.title.localizedCaseInsensitiveContains(title) })
        }
        if let index = request.windowIndex {
            return windows.first(where: { $0.index == index })
        }
        return windows.first(where: { $0.isKeyWindow == true })
            ?? windows.first(where: \.isMainWindow)
            ?? windows.min(by: { $0.index < $1.index })
    }

    private static func missingWindowReason(_ request: VerifyStateRequest) -> String {
        if let title = request.windowTitle {
            return "No window title contains '\(title)'"
        }
        if let index = request.windowIndex {
            return "Window index \(index) does not exist"
        }
        return "The application has no window"
    }

    private static func accessibilityEvidence(
        _ result: ElementDetectionResult,
        application: ServiceApplicationInfo,
        window: ServiceWindowInfo) -> VerifyStateAccessibilityEvidence
    {
        guard result.metadata.method == "AXorcist" else {
            return .unavailable(
                "Inspection method '\(result.metadata.method)' is not a fresh native AX traversal")
        }
        if let truncation = result.metadata.truncationInfo,
           truncation.maxDepthReached || truncation.maxElementCountReached ||
           truncation.maxChildrenPerNodeReached || truncation.deadlineReached
        {
            return .unavailable("Accessibility traversal was truncated")
        }
        let incompleteRead = result.metadata.truncationInfo?.incompleteAccessibilityRead == true
        let expectedWarnings = incompleteRead ? Set(["ax_incomplete_read"]) : []
        let unexpectedWarnings = result.metadata.warnings.filter { !expectedWarnings.contains($0) }
        if !unexpectedWarnings.isEmpty {
            return .unavailable(
                "Accessibility traversal reported warnings: \(unexpectedWarnings.joined(separator: ", "))")
        }
        if result.metadata.desktopMutationPreservationAllowed == false {
            return .unavailable("Accessibility state overlapped another desktop mutation")
        }
        guard result.metadata.windowContext?.applicationProcessId == application.processIdentifier else {
            return .unavailable("Accessibility result did not confirm target PID ownership")
        }
        guard result.metadata.windowContext?.windowID == window.windowID else {
            return .unavailable("Accessibility result did not confirm the exact target window")
        }
        if incompleteRead {
            return .incompleteTraversal(
                result.elements.all,
                reason: "Accessibility traversal was incomplete because one or more AX reads failed")
        }
        return .complete(result.elements.all)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private enum ApplicationResolution {
        case resolved(ServiceApplicationInfo)
        case missing(String)
        case unknown(String)
    }

    private enum WindowResolution {
        case resolved(ServiceWindowInfo)
        case missing(String)
        case unknown(String)
    }
}

struct VerifyStateResolvedApplication: Sendable {
    let application: ServiceApplicationInfo
    let processStartIdentity: UInt64
}

@MainActor
final class VerifyStateTargetIdentityTracker {
    enum Resolution {
        case resolved(VerifyStateResolvedApplication)
        case unknown(String)
    }

    enum GenerationStatus {
        case current
        case gone
        case unknown(String)
    }

    private let target: VerifyStateRequest.Target
    private let windowBoundsRequirements: [VerifyStateWindowBoundsRequirement]
    private let processStartIdentityProvider: @Sendable (pid_t) -> UInt64?
    private let initialExplicitProcessIdentity: UInt64?
    private var observedIdentities: [pid_t: UInt64] = [:]
    private var pinnedApplication: VerifyStateResolvedApplication?
    private var pinnedWindowReceipt: VerifyStateWindowReceipt?
    private var boundsTransitionAvailable = false
    private var windowIdentityFailure: String?

    init(
        target: VerifyStateRequest.Target,
        windowBoundsRequirements: [VerifyStateWindowBoundsRequirement] = [],
        processStartIdentityProvider: @escaping @Sendable (pid_t) -> UInt64?)
    {
        self.target = target
        self.windowBoundsRequirements = windowBoundsRequirements
        self.processStartIdentityProvider = processStartIdentityProvider
        self.initialExplicitProcessIdentity = if case let .pid(processIdentifier) = target {
            processStartIdentityProvider(processIdentifier)
        } else {
            nil
        }
    }

    func resolve(_ application: ServiceApplicationInfo) -> Resolution {
        let processIdentifier = pid_t(application.processIdentifier)
        guard let enumeratedIdentity = application.processStartIdentity else {
            return .unknown(
                "Application enumeration did not include a process-start identity for PID \(processIdentifier)")
        }
        guard let currentIdentity = self.processStartIdentityProvider(processIdentifier) else {
            return .unknown("Could not verify the process-start identity for PID \(processIdentifier)")
        }
        guard enumeratedIdentity == currentIdentity else {
            return .unknown(
                "PID \(processIdentifier) changed process identity after application enumeration")
        }

        if case let .pid(expectedProcessIdentifier) = self.target,
           processIdentifier != expectedProcessIdentifier
        {
            return .unknown(
                "PID resolution returned \(processIdentifier), not requested PID \(expectedProcessIdentifier)")
        }
        if case .pid = self.target {
            guard let initialExplicitProcessIdentity = self.initialExplicitProcessIdentity,
                  initialExplicitProcessIdentity == enumeratedIdentity
            else {
                return .unknown(
                    "PID \(processIdentifier) changed process identity after the explicit target was captured")
            }
        }

        if case .application = self.target,
           let pinnedApplication = self.pinnedApplication,
           pinnedApplication.application.processIdentifier != application.processIdentifier
        {
            return .unknown(
                "Application selector changed from pinned PID " +
                    "\(pinnedApplication.application.processIdentifier) to PID \(application.processIdentifier)")
        }

        if let observedIdentity = self.observedIdentities[processIdentifier],
           observedIdentity != currentIdentity
        {
            return .unknown("PID \(processIdentifier) changed process identity while verification was running")
        }
        self.observedIdentities[processIdentifier] = currentIdentity
        let resolved = VerifyStateResolvedApplication(
            application: application,
            processStartIdentity: currentIdentity)
        if case .application = self.target, self.pinnedApplication == nil {
            self.pinnedApplication = resolved
        }
        return .resolved(resolved)
    }

    func validate(_ resolved: VerifyStateResolvedApplication) -> String? {
        switch self.generationStatus(resolved) {
        case .current:
            nil
        case .gone:
            "PID \(resolved.application.processIdentifier) exited or its process identity became unavailable"
        case let .unknown(reason):
            reason
        }
    }

    func generationStatus(_ resolved: VerifyStateResolvedApplication) -> GenerationStatus {
        let processIdentifier = pid_t(resolved.application.processIdentifier)
        guard let currentIdentity = self.processStartIdentityProvider(processIdentifier) else {
            return .gone
        }
        guard currentIdentity == resolved.processStartIdentity,
              self.observedIdentities[processIdentifier] == resolved.processStartIdentity
        else {
            return .unknown("PID \(processIdentifier) changed process identity while verification was running")
        }
        return .current
    }

    func targetAbsenceFailure() -> String? {
        let pinnedProcess: (pid_t, UInt64)? = switch self.target {
        case let .pid(processIdentifier):
            self.observedIdentities[processIdentifier].map { (processIdentifier, $0) }
        case .application:
            self.pinnedApplication.map {
                (pid_t($0.application.processIdentifier), $0.processStartIdentity)
            }
        }

        guard let pinnedProcess else {
            if case let .pid(processIdentifier) = self.target,
               self.processStartIdentityProvider(processIdentifier) != nil
            {
                return "Application enumeration omitted live PID \(processIdentifier)"
            }
            return nil
        }
        guard let currentIdentity = self.processStartIdentityProvider(pinnedProcess.0) else {
            return nil
        }
        guard currentIdentity == pinnedProcess.1 else {
            return "PID \(pinnedProcess.0) changed process identity before absence could be confirmed"
        }
        return "Application enumeration omitted still-running pinned PID \(pinnedProcess.0)"
    }

    func validateWindow(
        _ window: SystemWindowIdentity,
        application: VerifyStateResolvedApplication) -> String?
    {
        if let windowIdentityFailure {
            return windowIdentityFailure
        }
        let expectedProcessIdentifier = application.application.processIdentifier
        guard window.ownerProcessIdentifier == expectedProcessIdentifier else {
            return self.failWindowIdentity(
                "Window \(window.windowID) changed owner or belongs to PID " +
                    "\(window.ownerProcessIdentifier), not target PID \(expectedProcessIdentifier)")
        }
        if let ownerProcessStartIdentity = window.ownerProcessStartIdentity,
           ownerProcessStartIdentity != application.processStartIdentity
        {
            return self.failWindowIdentity(
                "Window \(window.windowID) reported owner process generation \(ownerProcessStartIdentity), not " +
                    "the pinned generation \(application.processStartIdentity)")
        }
        return self.pinOrValidateWindowReceipt(
            windowID: window.windowID,
            ownerProcessIdentifier: window.ownerProcessIdentifier,
            ownerProcessStartIdentity: application.processStartIdentity,
            bounds: window.bounds)
    }

    func validateWindow(
        _ window: ServiceWindowInfo,
        application: VerifyStateResolvedApplication) -> String?
    {
        if let windowIdentityFailure {
            return windowIdentityFailure
        }
        guard let windowID = CGWindowID(exactly: window.windowID) else {
            return self.failWindowIdentity("Window inventory returned invalid window ID \(window.windowID)")
        }
        if let mutationIdentity = window.mutationIdentity {
            guard mutationIdentity.windowID == window.windowID,
                  mutationIdentity.ownerProcessIdentifier == application.application.processIdentifier,
                  mutationIdentity.ownerProcessStartIdentity == application.processStartIdentity
            else {
                return self.failWindowIdentity(
                    "Window \(window.windowID) inventory receipt did not match the pinned owner process generation")
            }
        }
        return self.pinOrValidateWindowReceipt(
            windowID: windowID,
            ownerProcessIdentifier: application.application.processIdentifier,
            ownerProcessStartIdentity: application.processStartIdentity,
            bounds: window.bounds)
    }

    func resolvedApplication(for application: ServiceApplicationInfo) -> VerifyStateResolvedApplication? {
        let processIdentifier = pid_t(application.processIdentifier)
        guard let identity = self.observedIdentities[processIdentifier] else { return nil }
        return VerifyStateResolvedApplication(application: application, processStartIdentity: identity)
    }

    private func pinOrValidateWindowReceipt(
        windowID: CGWindowID,
        ownerProcessIdentifier: pid_t,
        ownerProcessStartIdentity: UInt64,
        bounds: CGRect) -> String?
    {
        if let windowIdentityFailure {
            return windowIdentityFailure
        }
        let observed = VerifyStateWindowReceipt(
            windowID: windowID,
            ownerProcessIdentifier: ownerProcessIdentifier,
            ownerProcessStartIdentity: ownerProcessStartIdentity,
            bounds: bounds)
        guard let pinnedWindowReceipt else {
            self.pinnedWindowReceipt = observed
            self.boundsTransitionAvailable = !self.windowBoundsRequirements.isEmpty &&
                !self.windowBoundsRequirements.allSatisfy { $0.matches(bounds) }
            return nil
        }
        guard observed == pinnedWindowReceipt else {
            let stableIdentityMatches = observed.windowID == pinnedWindowReceipt.windowID &&
                observed.ownerProcessIdentifier == pinnedWindowReceipt.ownerProcessIdentifier &&
                observed.ownerProcessStartIdentity == pinnedWindowReceipt.ownerProcessStartIdentity
            if stableIdentityMatches,
               self.boundsTransitionAvailable,
               self.windowBoundsRequirements.allSatisfy({ $0.matches(observed.bounds) })
            {
                self.pinnedWindowReceipt = observed
                self.boundsTransitionAvailable = false
                return nil
            }
            let changedDiscriminator = if observed.windowID != pinnedWindowReceipt.windowID {
                "its resolved window ID changed"
            } else if observed.bounds != pinnedWindowReceipt.bounds {
                "its bounds changed"
            } else {
                "its owner process receipt changed"
            }
            return self.failWindowIdentity(
                "Pinned window \(pinnedWindowReceipt.windowID) verification receipt changed because " +
                    "\(changedDiscriminator) from " +
                    "\(pinnedWindowReceipt.description) to \(observed.description); " +
                    "the public WindowServer API exposes no stronger window-incarnation token")
        }
        return nil
    }

    private func failWindowIdentity(_ reason: String) -> String {
        self.windowIdentityFailure = reason
        return reason
    }
}

/// Fail-closed evidence that a session-scoped WindowServer ID still names the captured target.
/// Title, minimized/on-screen state, layer, and alpha are intentionally excluded because they
/// are mutable window state. Bounds are the strongest stable same-owner discriminator exposed
/// by the public WindowServer catalog.
private struct VerifyStateWindowReceipt: Sendable, Equatable {
    let windowID: CGWindowID
    let ownerProcessIdentifier: pid_t
    let ownerProcessStartIdentity: UInt64
    let bounds: CGRect

    var description: String {
        "ID \(self.windowID), PID \(self.ownerProcessIdentifier), generation " +
            "\(self.ownerProcessStartIdentity), bounds \(self.bounds)"
    }
}
