import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
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
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("confirmed_change"))
        #expect(meta["effect"] == .string("confirmed"))
    }

    @Test
    @MainActor
    func `canonical close failure survives the window tool error boundary`() async throws {
        let service = ExactRoutingWindowService()
        let failure = DesktopActionFailure.partial(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            unitCount: .one,
            message: "Window close was only partially applied")
        service.closeFailure = failure
        let context = await MCPToolTestHelpers.makeContext(windows: service)

        let response = try await WindowTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "close",
            "app": "Safari",
        ]))

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(failure.outcome, in: response)
    }

    @Test
    @MainActor
    func `restore readback failure preserves dispatched receipt as retry unsafe`() async throws {
        let service = ExactRoutingWindowService()
        service.postMutationReadbackError = UnexpectedWindowCall()
        let context = await MCPToolTestHelpers.makeContext(windows: service)

        let response = try await WindowTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "restore",
            "app": "Safari",
        ]))

        let expected = DesktopActionOutcome.indeterminate(
            route: .local,
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one)
        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(expected, in: response)
        #expect(service.restoreTargets.map(\.description) == ["windowId(924)"])
    }

    @Test
    @MainActor
    func `maximize empty readback preserves dispatched receipt as retry unsafe`() async throws {
        let service = ExactRoutingWindowService()
        service.postMutationReadbackIsEmpty = true
        let context = await MCPToolTestHelpers.makeContext(windows: service)

        let response = try await WindowTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "maximize",
            "app": "Safari",
        ]))

        let expected = DesktopActionOutcome.indeterminate(
            route: .local,
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one)
        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(expected, in: response)
        #expect(service.maximizeTargets.map(\.description) == ["windowId(924)"])
    }

    @Test
    @MainActor
    func `legacy restore readback failure does not fabricate action metadata`() async throws {
        let service = ExactRoutingWindowService()
        service.actionOutcome = nil
        service.postMutationReadbackError = UnexpectedWindowCall()
        let context = await MCPToolTestHelpers.makeContext(windows: service)

        let response = try await WindowTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "restore",
            "app": "Safari",
        ]))

        #expect(response.isError)
        let meta = response.meta?.objectValue ?? [:]
        #expect(MCPToolResponseMetadataProjector.actionOutcomeKeys.allSatisfy { meta[$0] == nil })
        #expect(service.restoreTargets.map(\.description) == ["windowId(924)"])
    }

    @MainActor
    private static func makeTool() -> WindowTool {
        WindowTool(context: MCPToolContext(services: PeekabooServices()))
    }
}

private final class ExactRoutingWindowService: WindowManagementActionResultProviding, @unchecked Sendable {
    nonisolated(unsafe) var actionOutcome: DesktopActionOutcome? = .confirmedChange(
        delivery: .init(mechanism: .accessibilityValue, mode: .background),
        unitCount: .one)
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
    nonisolated(unsafe) var closeFailure: DesktopActionFailure?
    nonisolated(unsafe) var postMutationReadbackError: (any Error)?
    nonisolated(unsafe) var postMutationReadbackIsEmpty = false

    func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo] {
        self.listTargets.append(target)
        if self.listTargets.count > 1 {
            if let postMutationReadbackError {
                throw postMutationReadbackError
            }
            if self.postMutationReadbackIsEmpty {
                return []
            }
        }
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

    func closeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        allowForegroundFallback: Bool) async throws -> DesktopActionResult<Void>
    {
        if let closeFailure {
            throw closeFailure
        }
        try await self.closeWindow(
            target: target,
            expectedIdentity: expectedIdentity,
            allowForegroundFallback: allowForegroundFallback)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func minimizeWindowActionResult(
        target: WindowTarget,
        expectedIdentity _: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        try await self.minimizeWindow(target: target)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func restoreWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        try await self.restoreWindow(target: target, expectedIdentity: expectedIdentity)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func maximizeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        try await self.maximizeWindow(target: target, expectedIdentity: expectedIdentity)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func moveWindowActionResult(
        target: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        to position: CGPoint) async throws -> DesktopActionResult<Void>
    {
        try await self.moveWindow(target: target, to: position)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func resizeWindowActionResult(
        target: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        to size: CGSize) async throws -> DesktopActionResult<Void>
    {
        try await self.resizeWindow(target: target, to: size)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func setWindowBoundsActionResult(
        target: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        bounds: CGRect) async throws -> DesktopActionResult<Void>
    {
        try await self.setWindowBounds(target: target, bounds: bounds)
        return DesktopActionResult(outcome: self.actionOutcome)
    }
}

private struct UnexpectedWindowCall: Error {}
