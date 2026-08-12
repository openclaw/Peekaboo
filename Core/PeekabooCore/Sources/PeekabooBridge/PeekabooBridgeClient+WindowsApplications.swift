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

    public func focusWindow(target: WindowTarget) async throws {
        try await self.sendExpectOK(.focusWindow(PeekabooBridgeWindowTargetRequest(target: target)))
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
        try await self.sendExpectOK(.moveWindow(PeekabooBridgeWindowMoveRequest(
            target: target,
            expectedIdentity: expectedIdentity,
            position: position)))
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
        try await self.sendExpectOK(.resizeWindow(PeekabooBridgeWindowResizeRequest(
            target: target,
            expectedIdentity: expectedIdentity,
            size: size)))
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
        try await self.sendExpectOK(.setWindowBounds(PeekabooBridgeWindowBoundsRequest(
            target: target,
            expectedIdentity: expectedIdentity,
            bounds: bounds)))
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
        let request = PeekabooBridgeWindowTargetRequest(
            target: target,
            expectedIdentity: expectedIdentity)
        if allowForegroundFallback {
            try await self.sendExpectOK(.closeWindow(request))
        } else {
            try await self.sendExpectOK(.backgroundCloseWindow(request))
        }
    }

    public func minimizeWindow(target: WindowTarget) async throws {
        let pinned = try await self.resolvedPinnedWindowMutation(target: target)
        try await self.minimizeWindow(target: pinned.target, expectedIdentity: pinned.identity)
    }

    public func minimizeWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws {
        try await self.sendExpectOK(.minimizeWindow(PeekabooBridgeWindowTargetRequest(
            target: target,
            expectedIdentity: expectedIdentity)))
    }

    public func restoreWindow(target: WindowTarget) async throws {
        let pinned = try await self.resolvedPinnedWindowMutation(target: target)
        try await self.restoreWindow(target: pinned.target, expectedIdentity: pinned.identity)
    }

    public func restoreWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws {
        try await self.sendExpectOK(.restoreWindow(PeekabooBridgeWindowTargetRequest(
            target: target,
            expectedIdentity: expectedIdentity)))
    }

    public func maximizeWindow(target: WindowTarget) async throws {
        let pinned = try await self.resolvedPinnedWindowMutation(target: target)
        try await self.maximizeWindow(target: pinned.target, expectedIdentity: pinned.identity)
    }

    public func maximizeWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws {
        try await self.sendExpectOK(.maximizeWindow(PeekabooBridgeWindowTargetRequest(
            target: target,
            expectedIdentity: expectedIdentity)))
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
        let response = try await self.send(
            .launchApplicationWithOptions(request),
            timeoutSec: Self.applicationLaunchRequestTimeout(
                defaultTimeoutSec: self.requestTimeoutSec,
                waitUntilReady: request.waitUntilReady,
                waitForWindow: request.waitForWindow))
        switch response {
        case let .application(app):
            return app
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected launchApplicationWithOptions response")
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
        guard request.waitSeconds.isFinite, request.waitSeconds >= 0 else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Relaunch wait must be a finite, non-negative number of seconds")
        }
        let response = try await self.send(
            .relaunchApplicationWithOptions(request),
            timeoutSec: Self.applicationRelaunchRequestTimeout(
                defaultTimeoutSec: self.requestTimeoutSec,
                waitSeconds: request.waitSeconds,
                waitUntilReady: request.launchRequest.waitUntilReady,
                waitForWindow: request.launchRequest.waitForWindow))
        switch response {
        case let .application(app):
            return app
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected relaunchApplicationWithOptions response")
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
        try await self.sendExpectOK(.activateApplication(PeekabooBridgeAppIdentifierRequest(identifier: identifier)))
    }

    public func activateApplication(request: ApplicationActivationRequest) async throws {
        try await self.sendExpectOK(.activateApplication(PeekabooBridgeAppIdentifierRequest(
            identifier: request.identifier,
            expectedIdentity: request.expectedIdentity)))
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
        let response = try await self.send(.quitApplication(payload))
        switch response {
        case let .bool(result):
            return result
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected quitApplication response")
        }
    }

    public func hideApplication(identifier: String) async throws {
        try await self.sendExpectOK(.hideApplication(PeekabooBridgeAppIdentifierRequest(identifier: identifier)))
    }

    public func unhideApplication(identifier: String) async throws {
        try await self.sendExpectOK(.unhideApplication(PeekabooBridgeAppIdentifierRequest(identifier: identifier)))
    }

    public func hideOtherApplications(identifier: String) async throws {
        try await self.sendExpectOK(.hideOtherApplications(PeekabooBridgeAppIdentifierRequest(identifier: identifier)))
    }

    public func showAllApplications() async throws {
        try await self.sendExpectOK(.showAllApplications)
    }
}
