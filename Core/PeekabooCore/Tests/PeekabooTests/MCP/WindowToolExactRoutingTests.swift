import CoreGraphics
import Foundation
import PeekabooAutomationKit
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

struct WindowToolExactRoutingTests {
    @Test
    @MainActor
    func `close pins a broad selector to the listed exact window`() async throws {
        let service = ExactRoutingWindowService()

        _ = try await Self.makeTool().handleClose(
            service: service,
            target: WindowActionTarget(target: .application("Safari"), expectedOwnerIdentity: nil),
            appName: "Safari",
            allowForegroundFallback: false,
            startTime: Date())

        #expect(service.listTargets.map(\.description) == ["application(Safari)"])
        #expect(service.closeTargets.map(\.description) == ["windowId(924)"])
        #expect(service.closeForegroundFallbacks == [false])
        #expect(service.receivedIdentities.map(\.ownerProcessStartIdentity) == [7])
        #expect(service.receivedIdentities.map(\.capturedBounds) == [
            CGRect(x: 100, y: 100, width: 800, height: 600),
        ])
    }

    @Test
    @MainActor
    func `maximize mutates and reads back the same exact window`() async throws {
        let service = ExactRoutingWindowService()

        _ = try await Self.makeTool().handleMaximize(
            service: service,
            target: WindowActionTarget(
                target: .applicationAndTitle(app: "Safari", title: "Fixture"),
                expectedOwnerIdentity: nil),
            appName: "Safari",
            startTime: Date())

        #expect(service.listTargets.map(\.description) == [
            "applicationAndTitle(app: Safari, title: Fixture)",
            "windowId(924)",
        ])
        #expect(service.maximizeTargets.map(\.description) == ["windowId(924)"])
        #expect(service.receivedIdentities.map(\.ownerProcessStartIdentity) == [7])
        #expect(service.receivedIdentities.map(\.capturedBounds) == [
            CGRect(x: 100, y: 100, width: 800, height: 600),
        ])
    }

    @Test
    @MainActor
    func `restore preserves exact minimized receipt and response formatting`() async throws {
        let service = ExactRoutingWindowService()

        let response = try await Self.makeTool().handleRestore(
            service: service,
            target: WindowActionTarget(
                target: .windowId(924),
                expectedOwnerIdentity: ApplicationProcessIdentity(
                    processIdentifier: 42,
                    processStartIdentity: 7)),
            appName: "PID:42",
            startTime: Date())

        #expect(service.restoreTargets.map(\.description) == ["windowId(924)"])
        #expect(service.receivedIdentities.last?.capturedBounds == CGRect(x: 100, y: 100, width: 800, height: 600))
        #expect(response.content.contains { block in
            guard case let .text(text, _, _) = block else { return false }
            return text.contains("Restored window 'Fixture'")
        })
    }

    @MainActor
    private static func makeTool() -> WindowTool {
        WindowTool(context: MCPToolContext(services: PeekabooServices()))
    }
}

private final class ExactRoutingWindowService: WindowManagementServiceProtocol, @unchecked Sendable {
    private let window = ServiceWindowInfo(
        windowID: 924,
        title: "Fixture",
        bounds: CGRect(x: 100, y: 100, width: 800, height: 600),
        mutationIdentity: .init(
            windowID: 924,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 7,
            capturedBounds: CGRect(x: 100, y: 100, width: 800, height: 600)))

    private(set) nonisolated(unsafe) var listTargets: [WindowTarget] = []
    private(set) nonisolated(unsafe) var closeTargets: [WindowTarget] = []
    private(set) nonisolated(unsafe) var closeForegroundFallbacks: [Bool] = []
    private(set) nonisolated(unsafe) var maximizeTargets: [WindowTarget] = []
    private(set) nonisolated(unsafe) var restoreTargets: [WindowTarget] = []
    private(set) nonisolated(unsafe) var receivedIdentities: [WindowMutationIdentity] = []

    func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo] {
        self.listTargets.append(target)
        return [self.window]
    }

    func closeWindow(target: WindowTarget) async throws {
        try await self.closeWindow(target: target, allowForegroundFallback: false)
    }

    func closeWindow(target: WindowTarget, allowForegroundFallback: Bool) async throws {
        self.closeTargets.append(target)
        self.closeForegroundFallbacks.append(allowForegroundFallback)
    }

    func closeWindow(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        allowForegroundFallback: Bool) async throws
    {
        self.receivedIdentities.append(expectedIdentity)
        try await self.closeWindow(target: target, allowForegroundFallback: allowForegroundFallback)
    }

    func maximizeWindow(target: WindowTarget) async throws {
        self.maximizeTargets.append(target)
    }

    func maximizeWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws {
        self.receivedIdentities.append(expectedIdentity)
        try await self.maximizeWindow(target: target)
    }

    func minimizeWindow(target _: WindowTarget) async throws {
        throw UnexpectedWindowCall()
    }

    func restoreWindow(target: WindowTarget) async throws {
        self.restoreTargets.append(target)
    }

    func restoreWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws {
        self.receivedIdentities.append(expectedIdentity)
        try await self.restoreWindow(target: target)
    }

    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {
        throw UnexpectedWindowCall()
    }

    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {
        throw UnexpectedWindowCall()
    }

    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {
        throw UnexpectedWindowCall()
    }

    func focusWindow(target _: WindowTarget) async throws {
        throw UnexpectedWindowCall()
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }
}

private struct UnexpectedWindowCall: Error {}
