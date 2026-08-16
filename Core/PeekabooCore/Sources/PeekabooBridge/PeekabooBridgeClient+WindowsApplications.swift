import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

extension PeekabooBridgeClient {
    public func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo] {
        let response = try await self.send(.listWindows(PeekabooBridgeWindowTargetRequest(target: target)))
        switch response {
        case let .windows(windows):
            return windows
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected listWindows response")
        }
    }

    public func listWindowMutationInventory(
        target: WindowTarget) async throws -> DesktopTargetPlanning.Inventory<ServiceWindowInfo>
    {
        guard self.windowMutationInventoryTransportEnabled else {
            return try await .partial(
                self.listWindows(target: target),
                warnings: ["Bridge host did not report window mutation inventory completeness."])
        }
        let response = try await self.send(.listWindowMutationInventory(
            PeekabooBridgeWindowTargetRequest(target: target)))
        switch response {
        case let .windowMutationInventory(inventory):
            return inventory
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected listWindowMutationInventory response")
        }
    }

    public func focusWindow(target: WindowTarget) async throws {
        _ = try await self.focusWindowResult(target: target)
    }

    public func focusWindowResult(target: WindowTarget) async throws -> UIAutomationActionResult<Void> {
        guard self.operationAttestation != nil else {
            return try await self.actionResult(
                for: .focusWindow(PeekabooBridgeWindowTargetRequest(target: target)),
                expectedResponse: "focusWindow")
            { response in
                switch response {
                case .ok, .window: ()
                default: nil
                }
            }
        }
        let pinned = try await self.resolvedPinnedWindowMutation(target: target)
        return try await self.focusWindowResult(
            target: pinned.target,
            expectedIdentity: pinned.identity)
    }

    public func focusWindowResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> UIAutomationActionResult<Void>
    {
        guard self.operationAttestation != nil else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "The selected Bridge protocol cannot bind focus to an exact window receipt.",
                hint: "Update the runtime host or use the explicit legacy unpinned focus API.")
        }
        return try await self.actionResult(
            for: .focusWindow(PeekabooBridgeWindowTargetRequest(
                target: target,
                expectedIdentity: expectedIdentity)),
            expectedResponse: "focusWindow")
        { response in
            switch response {
            case .ok, .window: ()
            default: nil
            }
        }
    }

    public func moveWindow(target: WindowTarget, to position: CGPoint) async throws {
        let pinned = try await self.resolvedPinnedWindowMutation(target: target)
        try await self.moveWindow(
            target: pinned.target,
            expectedIdentity: pinned.identity,
            to: position)
    }

    public func moveWindow(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to position: CGPoint) async throws
    {
        _ = try await self.moveWindowResult(
            target: target,
            expectedIdentity: expectedIdentity,
            to: position)
    }

    public func moveWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to position: CGPoint) async throws -> DesktopActionOutcome?
    {
        try await self.moveWindowResult(
            target: target,
            expectedIdentity: expectedIdentity,
            to: position).outcome
    }

    public func moveWindowResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to position: CGPoint) async throws -> DesktopActionResult<Void>
    {
        let outcome = try await self.windowMutationOutcome(.moveWindow(PeekabooBridgeWindowMoveRequest(
            target: target,
            expectedIdentity: expectedIdentity,
            position: position)))
        return DesktopActionResult(outcome: outcome)
    }

    public func resizeWindow(target: WindowTarget, to size: CGSize) async throws {
        let pinned = try await self.resolvedPinnedWindowMutation(target: target)
        try await self.resizeWindow(target: pinned.target, expectedIdentity: pinned.identity, to: size)
    }

    public func resizeWindow(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to size: CGSize) async throws
    {
        _ = try await self.resizeWindowResult(
            target: target,
            expectedIdentity: expectedIdentity,
            to: size)
    }

    public func resizeWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to size: CGSize) async throws -> DesktopActionOutcome?
    {
        try await self.resizeWindowResult(
            target: target,
            expectedIdentity: expectedIdentity,
            to: size).outcome
    }

    public func resizeWindowResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to size: CGSize) async throws -> DesktopActionResult<Void>
    {
        let outcome = try await self.windowMutationOutcome(.resizeWindow(PeekabooBridgeWindowResizeRequest(
            target: target,
            expectedIdentity: expectedIdentity,
            size: size)))
        return DesktopActionResult(outcome: outcome)
    }

    public func setWindowBounds(target: WindowTarget, bounds: CGRect) async throws {
        let pinned = try await self.resolvedPinnedWindowMutation(target: target)
        try await self.setWindowBounds(
            target: pinned.target,
            expectedIdentity: pinned.identity,
            bounds: bounds)
    }

    public func setWindowBounds(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        bounds: CGRect) async throws
    {
        _ = try await self.setWindowBoundsResult(
            target: target,
            expectedIdentity: expectedIdentity,
            bounds: bounds)
    }

    public func setWindowBoundsWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        bounds: CGRect) async throws -> DesktopActionOutcome?
    {
        try await self.setWindowBoundsResult(
            target: target,
            expectedIdentity: expectedIdentity,
            bounds: bounds).outcome
    }

    public func setWindowBoundsResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        bounds: CGRect) async throws -> DesktopActionResult<Void>
    {
        let outcome = try await self
            .windowMutationOutcome(.setWindowBounds(PeekabooBridgeWindowBoundsRequest(
                target: target,
                expectedIdentity: expectedIdentity,
                bounds: bounds)))
        return DesktopActionResult(outcome: outcome)
    }

    public func closeWindow(target: WindowTarget) async throws {
        try await self.closeWindow(target: target, allowForegroundFallback: false)
    }

    public func closeWindow(target: WindowTarget, allowForegroundFallback: Bool) async throws {
        let pinned = try await self.resolvedPinnedWindowMutation(target: target)
        try await self.closeWindow(
            target: pinned.target,
            expectedIdentity: pinned.identity,
            allowForegroundFallback: allowForegroundFallback)
    }

    public func closeWindow(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        allowForegroundFallback: Bool) async throws
    {
        _ = try await self.closeWindowResult(
            target: target,
            expectedIdentity: expectedIdentity,
            allowForegroundFallback: allowForegroundFallback)
    }

    public func closeWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionOutcome?
    {
        try await self.closeWindowResult(
            target: target,
            expectedIdentity: expectedIdentity,
            allowForegroundFallback: false).outcome
    }

    public func closeWindowResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        allowForegroundFallback: Bool) async throws -> DesktopActionResult<Void>
    {
        if allowForegroundFallback {
            let outcome = try await self.windowMutationOutcome(.closeWindow(
                PeekabooBridgeWindowTargetRequest(
                    target: target,
                    expectedIdentity: expectedIdentity)))
            return DesktopActionResult(outcome: outcome)
        }
        let outcome = try await self.windowMutationOutcome(.backgroundCloseWindow(.init(
            target: target,
            expectedIdentity: expectedIdentity)))
        return DesktopActionResult(outcome: outcome)
    }

    public func minimizeWindow(target: WindowTarget) async throws {
        let pinned = try await self.resolvedPinnedWindowMutation(target: target)
        try await self.minimizeWindow(target: pinned.target, expectedIdentity: pinned.identity)
    }

    public func minimizeWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws {
        _ = try await self.minimizeWindowResult(target: target, expectedIdentity: expectedIdentity)
    }

    public func minimizeWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionOutcome?
    {
        try await self.minimizeWindowResult(target: target, expectedIdentity: expectedIdentity).outcome
    }

    public func minimizeWindowResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        let outcome = try await self
            .windowMutationOutcome(.minimizeWindow(PeekabooBridgeWindowTargetRequest(
                target: target,
                expectedIdentity: expectedIdentity)))
        return DesktopActionResult(outcome: outcome)
    }

    public func restoreWindow(target: WindowTarget) async throws {
        let pinned = try await self.resolvedPinnedWindowMutation(target: target)
        try await self.restoreWindow(target: pinned.target, expectedIdentity: pinned.identity)
    }

    public func restoreWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws {
        _ = try await self.restoreWindowResult(target: target, expectedIdentity: expectedIdentity)
    }

    public func restoreWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionOutcome?
    {
        try await self.restoreWindowResult(target: target, expectedIdentity: expectedIdentity).outcome
    }

    public func restoreWindowResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        let outcome = try await self.windowMutationOutcome(.restoreWindow(PeekabooBridgeWindowTargetRequest(
            target: target,
            expectedIdentity: expectedIdentity)))
        return DesktopActionResult(outcome: outcome)
    }

    public func maximizeWindow(target: WindowTarget) async throws {
        let pinned = try await self.resolvedPinnedWindowMutation(target: target)
        try await self.maximizeWindow(target: pinned.target, expectedIdentity: pinned.identity)
    }

    public func maximizeWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws {
        _ = try await self.maximizeWindowResult(target: target, expectedIdentity: expectedIdentity)
    }

    public func maximizeWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionOutcome?
    {
        try await self.maximizeWindowResult(target: target, expectedIdentity: expectedIdentity).outcome
    }

    public func maximizeWindowResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        let outcome = try await self
            .windowMutationOutcome(.maximizeWindow(PeekabooBridgeWindowTargetRequest(
                target: target,
                expectedIdentity: expectedIdentity)))
        return DesktopActionResult(outcome: outcome)
    }

    package func resolvedPinnedWindowMutation(
        target: WindowTarget) async throws -> (target: WindowTarget, identity: WindowMutationIdentity)
    {
        guard let window = try await self.listWindows(target: target).first else {
            throw PeekabooError.windowNotFound(criteria: "No window matched \(target)")
        }
        guard let identity = window.mutationIdentity else {
            throw PeekabooError.serviceUnavailable(
                "Bridge host did not return process-generation identity for window \(window.windowID)")
        }
        return (.windowId(window.windowID), identity)
    }

    public func getFocusedWindow() async throws -> ServiceWindowInfo? {
        let response = try await self.send(.getFocusedWindow)
        switch response {
        case let .window(info):
            return info
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected getFocusedWindow response")
        }
    }

    public func listApplications() async throws -> [ServiceApplicationInfo] {
        let response = try await self.send(.listApplications)
        switch response {
        case let .applications(apps):
            return apps
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected listApplications response")
        }
    }

    public func listApplicationMutationInventory() async throws
        -> DesktopTargetPlanning.Inventory<ServiceApplicationInfo>
    {
        guard self.applicationMutationInventoryTransportEnabled else {
            return try await .partial(
                self.listApplications(),
                warnings: ["Bridge host did not report application mutation inventory completeness."])
        }
        let response = try await self.send(.listApplicationMutationInventory)
        switch response {
        case let .applicationMutationInventory(inventory):
            return inventory
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected listApplicationMutationInventory response")
        }
    }

    public func findApplication(identifier: String) async throws -> ServiceApplicationInfo {
        let response = try await self.send(.findApplication(PeekabooBridgeAppIdentifierRequest(identifier: identifier)))
        switch response {
        case let .application(app):
            return app
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected findApplication response")
        }
    }

    public func getFrontmostApplication() async throws -> ServiceApplicationInfo {
        let response = try await self.send(.getFrontmostApplication)
        switch response {
        case let .application(app):
            return app
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected frontmost application response")
        }
    }

    public func isApplicationRunning(identifier: String) async throws -> Bool {
        let response = try await self
            .send(.isApplicationRunning(PeekabooBridgeAppIdentifierRequest(identifier: identifier)))
        switch response {
        case let .bool(running):
            return running
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected isApplicationRunning response")
        }
    }

    public func launchApplication(identifier: String) async throws -> ServiceApplicationInfo {
        let response = try await self
            .send(.launchApplication(PeekabooBridgeAppIdentifierRequest(identifier: identifier)))
        switch response {
        case let .application(app):
            return app
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected launchApplication response")
        }
    }

    public func launchApplication(request: ApplicationLaunchRequest) async throws -> ServiceApplicationInfo {
        try await self.launchApplicationResult(request: request).payload
    }

    public func launchApplicationResult(
        request: ApplicationLaunchRequest) async throws -> DesktopActionResult<ServiceApplicationInfo>
    {
        let bridgeRequest = PeekabooBridgeRequest.launchApplicationWithOptions(request)
        let carriedRequest: PeekabooBridgeRequest = if request.isSafeBackgroundNoOp,
                                                       self.operationAttestation != nil
        {
            .projectedAction(.init(request: bridgeRequest))
        } else {
            bridgeRequest
        }
        return try await self.sendApplicationAction(
            carriedRequest,
            timeoutSec: Self.applicationLaunchRequestTimeout(
                defaultTimeoutSec: self.requestTimeoutSec,
                waitUntilReady: request.waitUntilReady,
                waitForWindow: request.waitForWindow),
            operation: "launchApplicationWithOptions")
        { response in
            guard case let .application(application) = response else { return nil }
            return application
        }
    }

    static func applicationLaunchRequestTimeout(
        defaultTimeoutSec: TimeInterval,
        waitUntilReady: Bool,
        waitForWindow: Bool = false) -> TimeInterval?
    {
        waitUntilReady || waitForWindow ? max(defaultTimeoutSec, 30) : nil
    }

    public func relaunchApplication(request: ApplicationRelaunchRequest) async throws -> ServiceApplicationInfo {
        try await self.relaunchApplicationResult(request: request).payload
    }

    public func relaunchApplicationResult(
        request: ApplicationRelaunchRequest) async throws -> DesktopActionResult<ServiceApplicationInfo>
    {
        guard request.waitSeconds.isFinite, request.waitSeconds >= 0 else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Relaunch wait must be a finite, non-negative number of seconds")
        }
        return try await self.sendApplicationAction(
            .relaunchApplicationWithOptions(request),
            timeoutSec: Self.applicationRelaunchRequestTimeout(
                defaultTimeoutSec: self.requestTimeoutSec,
                waitSeconds: request.waitSeconds,
                waitUntilReady: request.launchRequest.waitUntilReady,
                waitForWindow: request.launchRequest.waitForWindow),
            operation: "relaunchApplicationWithOptions")
        { response in
            guard case let .application(application) = response else { return nil }
            return application
        }
    }

    static func applicationRelaunchRequestTimeout(
        defaultTimeoutSec: TimeInterval,
        waitSeconds: TimeInterval,
        waitUntilReady: Bool,
        waitForWindow: Bool = false) -> TimeInterval
    {
        let transactionAllowance = max(0, waitSeconds) + (waitUntilReady || waitForWindow ? 25 : 15)
        return max(defaultTimeoutSec, transactionAllowance)
    }

    public func activateApplication(identifier: String) async throws {
        guard self.operationAttestation != nil else {
            try await self.sendExpectOK(
                .activateApplication(PeekabooBridgeAppIdentifierRequest(identifier: identifier)))
            return
        }
        let application = try await self.findApplication(identifier: identifier)
        guard let expectedIdentity = application.processIdentity else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Bridge host did not return a stable process-generation identity for \(identifier)")
        }
        try await self.activateApplication(request: .init(
            identifier: "PID:\(application.processIdentifier)",
            expectedIdentity: expectedIdentity))
    }

    public func activateApplication(request: ApplicationActivationRequest) async throws {
        _ = try await self.activateApplicationResult(request: request)
    }

    public func activateApplicationResult(
        request: ApplicationActivationRequest) async throws -> DesktopActionResult<Void>
    {
        try await self.activateApplicationTargetedResult(request: request).desktopActionResult
    }

    public func activateApplicationTargetedResult(
        request: ApplicationActivationRequest) async throws -> UIAutomationActionResult<Void>
    {
        if self.operationAttestation != nil, request.expectedIdentity == nil {
            let application = try await self.findApplication(identifier: request.identifier)
            guard let expectedIdentity = application.processIdentity else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .operationNotSupported,
                    message: "Bridge host did not return a stable process-generation identity for " +
                        request.identifier)
            }
            return try await self.activateApplicationTargetedResult(request: .init(
                identifier: "PID:\(application.processIdentifier)",
                expectedIdentity: expectedIdentity))
        }
        return try await self.actionResult(
            for: .activateApplication(PeekabooBridgeAppIdentifierRequest(
                identifier: request.identifier,
                expectedIdentity: request.expectedIdentity)),
            expectedResponse: "activateApplication")
        { response in
            guard case .ok = response else { return nil }
            return ()
        }
    }

    public func quitApplication(
        identifier: String,
        force: Bool,
        supportsPinnedQuit: Bool = false) async throws -> Bool
    {
        guard supportsPinnedQuit else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Bridge host lacks process-generation-pinned application quit; update the host")
        }
        let selectedApplication = try await self.findApplication(identifier: identifier)
        guard let expectedIdentity = selectedApplication.processIdentity else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Bridge host did not return a stable process-generation identity for \(identifier)")
        }
        return try await self.quitApplication(
            request: ApplicationQuitRequest(
                identifier: "PID:\(selectedApplication.processIdentifier)",
                force: force,
                expectedIdentity: expectedIdentity),
            supportsPinnedQuit: true)
    }

    public func quitApplication(
        request: ApplicationQuitRequest,
        supportsPinnedQuit: Bool = false) async throws -> Bool
    {
        try await self.quitApplicationResult(
            request: request,
            supportsPinnedQuit: supportsPinnedQuit).payload
    }

    public func quitApplicationResult(
        request: ApplicationQuitRequest,
        supportsPinnedQuit: Bool = false) async throws -> DesktopActionResult<Bool>
    {
        guard supportsPinnedQuit else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Bridge host lacks process-generation-pinned application quit; update the host")
        }
        guard request.expectedIdentity != nil else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Bridge application quit requires a process-generation identity; resolve the app again")
        }
        let payload = PeekabooBridgeQuitAppRequest(request)
        return try await self.sendApplicationAction(
            .quitApplication(payload),
            operation: "quitApplication")
        { response in
            guard case let .bool(success) = response else { return nil }
            return success
        }
    }

    public func hideApplication(identifier: String) async throws {
        _ = try await self.hideApplicationResult(identifier: identifier)
    }

    public func hideApplicationResult(identifier: String) async throws -> DesktopActionResult<Void> {
        try await self.hideApplicationTargetedResult(identifier: identifier).desktopActionResult
    }

    public func hideApplicationTargetedResult(
        identifier: String) async throws -> UIAutomationActionResult<Void>
    {
        guard self.operationAttestation != nil else {
            return try await self.actionResult(
                for: .hideApplication(PeekabooBridgeAppIdentifierRequest(identifier: identifier)),
                expectedResponse: "hideApplication")
            { response in
                guard case .ok = response else { return nil }
                return ()
            }
        }
        let application = try await self.findApplication(identifier: identifier)
        guard let identity = application.processIdentity else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Bridge host did not return a stable process-generation identity for \(identifier)")
        }
        let request = try ApplicationHideRequest(
            identifier: "PID:\(identity.processIdentifier)",
            expectedIdentity: identity)
        return try await self.hideApplicationTargetedResult(request: request)
    }

    public func hideApplicationTargetedResult(
        request: ApplicationHideRequest) async throws -> UIAutomationActionResult<Void>
    {
        try await self.actionResult(
            for: .hideApplication(PeekabooBridgeAppIdentifierRequest(request)),
            expectedResponse: "hideApplication",
            operationReceiptRequirement: .required)
        { response in
            guard case .ok = response else { return nil }
            return ()
        }
    }

    public func unhideApplication(identifier: String) async throws {
        _ = try await self.unhideApplicationResult(identifier: identifier)
    }

    public func unhideApplicationResult(identifier: String) async throws -> DesktopActionResult<Void> {
        let outcome = try await self.sendExpectOKCarryingActionOutcome(
            .unhideApplication(PeekabooBridgeAppIdentifierRequest(identifier: identifier)))
        return DesktopActionResult(outcome: outcome)
    }

    public func hideOtherApplications(identifier: String) async throws {
        _ = try await self.hideOtherApplicationsResult(identifier: identifier)
    }

    public func hideOtherApplicationsResult(identifier: String) async throws -> DesktopActionResult<Void> {
        let outcome = try await self.sendExpectOKCarryingActionOutcome(
            .hideOtherApplications(PeekabooBridgeAppIdentifierRequest(identifier: identifier)))
        return DesktopActionResult(outcome: outcome)
    }

    public func showAllApplications() async throws {
        _ = try await self.showAllApplicationsResult()
    }

    public func showAllApplicationsResult() async throws -> DesktopActionResult<Void> {
        let outcome = try await self.sendExpectOKCarryingActionOutcome(.showAllApplications)
        return DesktopActionResult(outcome: outcome)
    }

    private func sendApplicationAction<Payload: Sendable>(
        _ request: PeekabooBridgeRequest,
        timeoutSec: TimeInterval? = nil,
        operation: String,
        payload: (PeekabooBridgeResponse) -> Payload?) async throws -> DesktopActionResult<Payload>
    {
        let reply = try await self.sendCarryingActionOutcome(request, timeoutSec: timeoutSec)
        if case let .error(envelope) = reply.response {
            try Self.throwActionFailureOrEnvelope(envelope)
        }
        guard let value = payload(reply.response) else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected \(operation) response")
        }
        return DesktopActionResult(payload: value, outcome: reply.outcome?.outcome)
    }

    private func windowMutationOutcome(_ request: PeekabooBridgeRequest) async throws -> DesktopActionOutcome? {
        let reply = try await self.sendCarryingActionOutcome(request)
        switch reply.response {
        case .ok, .window:
            return reply.outcome?.outcome
        case let .error(envelope):
            try Self.throwActionFailureOrEnvelope(envelope)
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected response for window mutation")
        }
    }
}
