import CoreGraphics
import MCP
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable @_spi(Testing) import PeekabooAutomationKit

@Suite(.serialized)
@MainActor
struct VerifyStateWindowReceiptTests {
    @Test
    func `Same PID and window ID with changed bounds is unknown across poll samples`() async throws {
        let fixture = VerifyStateFixture()
        let context = await fixture.context(results: [])
        let initial = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: fixture.window.bounds)
        let replacement = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: fixture.window.bounds.offsetBy(dx: 80, dy: 40))
        let windows = LockedSystemWindowIdentitySequence([initial, replacement])
        let tool = fixture.tool(
            context: context,
            windowIdentityProvider: { _ in windows.next() })

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [["kind": "window_exists", "expected": true]],
            "timeout_ms": 250,
        ]))

        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.stringMeta("reason", response)?.contains("verification receipt changed") == true)
        #expect(Self.stringMeta("reason", response)?.contains("no stronger window-incarnation token") == true)
        #expect(Self.intMeta("stable_samples", response) == 0)
    }

    @Test
    func `Window bounds may transition directly to expected bounds then stabilize`() async throws {
        let fixture = VerifyStateFixture()
        let context = await fixture.context(results: [])
        let expectedBounds = fixture.window.bounds.offsetBy(dx: 80, dy: 40)
        let initial = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: fixture.window.bounds)
        let expected = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: expectedBounds)
        let windows = LockedSystemWindowIdentitySequence([initial, expected, expected])
        let tool = fixture.tool(
            context: context,
            windowIdentityProvider: { _ in windows.next() })

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [[
                "kind": "window_bounds",
                "bounds": Self.boundsArguments(expectedBounds),
                "tolerance": 0,
            ]],
            "timeout_ms": 400,
        ]))

        #expect(Self.stringMeta("status", response) == "satisfied")
        #expect(Self.intMeta("sample_count", response) == 3)
        #expect(Self.intMeta("stable_samples", response) == 2)
    }

    @Test
    func `Unexpected intermediate bounds make a later expected transition unknown`() async throws {
        let fixture = VerifyStateFixture()
        let context = await fixture.context(results: [])
        let intermediateBounds = fixture.window.bounds.offsetBy(dx: 20, dy: 10)
        let expectedBounds = fixture.window.bounds.offsetBy(dx: 80, dy: 40)
        let initial = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: fixture.window.bounds)
        let intermediate = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: intermediateBounds)
        let expected = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: expectedBounds)
        let windows = LockedSystemWindowIdentitySequence([initial, intermediate, expected])
        let tool = fixture.tool(
            context: context,
            windowIdentityProvider: { _ in windows.next() })

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [[
                "kind": "window_bounds",
                "bounds": Self.boundsArguments(expectedBounds),
                "tolerance": 0,
            ]],
            "timeout_ms": 350,
        ]))

        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.stringMeta("reason", response)?.contains("verification receipt changed") == true)
        #expect(Self.intMeta("stable_samples", response) == 0)
    }

    @Test
    func `Drift after the permitted expected bounds transition is unknown`() async throws {
        let fixture = VerifyStateFixture()
        let context = await fixture.context(results: [])
        let expectedBounds = fixture.window.bounds.offsetBy(dx: 80, dy: 40)
        let driftedBounds = expectedBounds.offsetBy(dx: 1, dy: 0)
        let initial = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: fixture.window.bounds)
        let expected = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: expectedBounds)
        let drifted = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: driftedBounds)
        let windows = LockedSystemWindowIdentitySequence([initial, expected, drifted])
        let tool = fixture.tool(
            context: context,
            windowIdentityProvider: { _ in windows.next() })

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [[
                "kind": "window_bounds",
                "bounds": Self.boundsArguments(expectedBounds),
                "tolerance": 2,
            ]],
            "timeout_ms": 350,
        ]))

        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.stringMeta("reason", response)?.contains("verification receipt changed") == true)
        #expect(Self.intMeta("stable_samples", response) == 0)
    }

    @Test
    func `Contradictory bounds predicates never broaden the permitted transition`() async throws {
        let fixture = VerifyStateFixture()
        let context = await fixture.context(results: [])
        let firstExpectedBounds = fixture.window.bounds.offsetBy(dx: 80, dy: 40)
        let secondExpectedBounds = fixture.window.bounds.offsetBy(dx: 160, dy: 80)
        let initial = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: fixture.window.bounds)
        let onlyFirstMatches = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: firstExpectedBounds)
        let windows = LockedSystemWindowIdentitySequence([initial, onlyFirstMatches])
        let tool = fixture.tool(
            context: context,
            windowIdentityProvider: { _ in windows.next() })

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [
                [
                    "kind": "window_bounds",
                    "bounds": Self.boundsArguments(firstExpectedBounds),
                    "tolerance": 0,
                ],
                [
                    "kind": "window_bounds",
                    "bounds": Self.boundsArguments(secondExpectedBounds),
                    "tolerance": 0,
                ],
            ],
            "timeout_ms": 300,
        ]))

        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.stringMeta("reason", response)?.contains("verification receipt changed") == true)
        #expect(Self.intMeta("stable_samples", response) == 0)
    }

    @Test
    func `Repinned expected bounds are enforced after final screenshot capture`() async throws {
        let fixture = VerifyStateFixture()
        let expectedBounds = fixture.window.bounds.offsetBy(dx: 80, dy: 40)
        let expectedWindow = ServiceWindowInfo(
            windowID: fixture.window.windowID,
            title: fixture.window.title,
            bounds: expectedBounds,
            isMainWindow: true)
        let capture = VerifyStateScreenCaptureService(
            applicationInfo: fixture.application,
            windowInfo: expectedWindow)
        let context = await fixture.context(results: [], screenCapture: capture)
        let initial = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: fixture.window.bounds)
        let expected = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: expectedBounds)
        let drifted = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: expectedBounds.offsetBy(dx: 1, dy: 0))
        let windows = LockedSystemWindowIdentitySequence([initial, expected, expected, drifted])
        let tool = fixture.tool(
            context: context,
            windowIdentityProvider: { _ in windows.next() })

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [[
                "kind": "window_bounds",
                "bounds": Self.boundsArguments(expectedBounds),
                "tolerance": 0,
            ]],
            "timeout_ms": 500,
            "stable_samples": 1,
            "final_screenshot": true,
        ]))

        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.intMeta("stable_samples", response) == 0)
        #expect(Self.boolMeta("screenshot_attached", response) == false)
        #expect(Self.stringMeta("screenshot_error", response)?.contains("verification receipt changed") == true)
        #expect(capture.windowIDs == [CGWindowID(fixture.window.windowID)])
    }

    @Test
    func `Mutable window presentation does not change an otherwise identical receipt`() async throws {
        let fixture = VerifyStateFixture()
        let context = await fixture.context(results: [])
        let initial = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: fixture.window.bounds)
        let retitledOffscreen = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: fixture.window.bounds,
            title: "Verifier — Updated",
            isOnScreen: false)
        let windows = LockedSystemWindowIdentitySequence([initial, retitledOffscreen])
        let tool = fixture.tool(
            context: context,
            windowIdentityProvider: { _ in windows.next() })

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [["kind": "window_exists", "expected": true]],
            "timeout_ms": 250,
        ]))

        #expect(Self.stringMeta("status", response) == "satisfied")
        #expect(Self.intMeta("stable_samples", response) == 2)
    }

    private static func boundsArguments(_ bounds: CGRect) -> [String: Double] {
        [
            "x": Double(bounds.origin.x),
            "y": Double(bounds.origin.y),
            "width": Double(bounds.width),
            "height": Double(bounds.height),
        ]
    }

    private static func stringMeta(_ key: String, _ response: ToolResponse) -> String? {
        guard case let .object(metadata) = response.meta,
              case let .string(value)? = metadata[key]
        else { return nil }
        return value
    }

    private static func intMeta(_ key: String, _ response: ToolResponse) -> Int? {
        guard case let .object(metadata) = response.meta,
              case let .int(value)? = metadata[key]
        else { return nil }
        return value
    }

    private static func boolMeta(_ key: String, _ response: ToolResponse) -> Bool? {
        guard case let .object(metadata) = response.meta,
              case let .bool(value)? = metadata[key]
        else { return nil }
        return value
    }
}
