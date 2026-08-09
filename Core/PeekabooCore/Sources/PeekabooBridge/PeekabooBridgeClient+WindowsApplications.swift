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
        try await self.sendExpectOK(.moveWindow(PeekabooBridgeWindowMoveRequest(target: target, position: position)))
    }

    public func resizeWindow(target: WindowTarget, to size: CGSize) async throws {
        try await self.sendExpectOK(.resizeWindow(PeekabooBridgeWindowResizeRequest(target: target, size: size)))
    }

    public func setWindowBounds(target: WindowTarget, bounds: CGRect) async throws {
        try await self.sendExpectOK(.setWindowBounds(PeekabooBridgeWindowBoundsRequest(target: target, bounds: bounds)))
    }

    public func closeWindow(target: WindowTarget) async throws {
        try await self.closeWindow(target: target, allowForegroundFallback: false)
    }

    public func closeWindow(target: WindowTarget, allowForegroundFallback: Bool) async throws {
        let request = PeekabooBridgeWindowTargetRequest(target: target)
        if allowForegroundFallback {
            try await self.sendExpectOK(.closeWindow(request))
        } else {
            try await self.sendExpectOK(.backgroundCloseWindow(request))
        }
    }

    public func minimizeWindow(target: WindowTarget) async throws {
        try await self.sendExpectOK(.minimizeWindow(PeekabooBridgeWindowTargetRequest(target: target)))
    }

    public func maximizeWindow(target: WindowTarget) async throws {
        try await self.sendExpectOK(.maximizeWindow(PeekabooBridgeWindowTargetRequest(target: target)))
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
                waitUntilReady: request.waitUntilReady))
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
        waitUntilReady: Bool) -> TimeInterval?
    {
        waitUntilReady ? max(defaultTimeoutSec, 30) : nil
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
                waitUntilReady: request.launchRequest.waitUntilReady))
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
        waitUntilReady: Bool) -> TimeInterval
    {
        let transactionAllowance = max(0, waitSeconds) + (waitUntilReady ? 25 : 15)
        return max(defaultTimeoutSec, transactionAllowance)
    }

    public func activateApplication(identifier: String) async throws {
        try await self.sendExpectOK(.activateApplication(PeekabooBridgeAppIdentifierRequest(identifier: identifier)))
    }

    public func quitApplication(identifier: String, force: Bool) async throws -> Bool {
        let payload = PeekabooBridgeQuitAppRequest(identifier: identifier, force: force)
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
