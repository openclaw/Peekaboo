import MCP
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@Suite(.serialized)
@MainActor
struct VerifyStateIncompleteEvidenceTests {
    @Test
    func `Incomplete unrelated AX reads preserve stable exact identifier value proof`() async throws {
        let fixture = VerifyStateFixture()
        let incomplete = fixture.result(
            elements: [
                fixture.element(identifier: "basic-text-field", label: "Text", value: "Expected"),
                fixture.element(identifier: "unrelated-sibling", label: "Sibling", value: "Other"),
            ],
            truncationInfo: DetectionTruncationInfo(incompleteAccessibilityRead: true),
            warnings: ["ax_incomplete_read"])
        let context = await fixture.context(results: [incomplete, incomplete])

        let response = try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [[
                "kind": "element_value",
                "selector": ["identifier": "basic-text-field"],
                "expected_value": "Expected",
            ]],
            "timeout_ms": 500,
            "stable_samples": 2,
        ]))

        #expect(Self.stringMeta("status", response) == "satisfied")
        #expect(Self.intMeta("stable_samples", response) == 2)
        #expect(Self.intMeta("sample_count", response) == 2)
    }

    @Test
    func `Incomplete AX reads cannot prove missing mismatched or non-identifier values`() async throws {
        let fixture = VerifyStateFixture()
        let cases: [(elements: [DetectedElement], selector: [String: String], expected: String)] = [
            ([], ["identifier": "basic-text-field"], "Expected"),
            (
                [fixture.element(identifier: "basic-text-field", label: "Text", value: "Actual")],
                ["identifier": "basic-text-field"],
                "Expected"),
            (
                [fixture.element(identifier: "basic-text-field", label: "Text", value: "Expected")],
                ["label": "Text"],
                "Expected"),
        ]

        for testCase in cases {
            let incomplete = fixture.result(
                elements: testCase.elements,
                truncationInfo: DetectionTruncationInfo(incompleteAccessibilityRead: true),
                warnings: ["ax_incomplete_read"])
            let context = await fixture.context(results: [incomplete])
            let response = try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: [
                "pid": Int(fixture.application.processIdentifier),
                "window_id": fixture.window.windowID,
                "predicates": [[
                    "kind": "element_value",
                    "selector": testCase.selector,
                    "expected_value": testCase.expected,
                ]],
                "timeout_ms": 100,
                "stable_samples": 1,
            ]))

            #expect(Self.stringMeta("status", response) == "unknown")
            #expect(Self.stringMeta("reason", response)?.contains("incomplete") == true)
            #expect(Self.intMeta("stable_samples", response) == 0)
        }
    }

    @Test
    func `Incomplete AX reads keep duplicate exact identifiers ambiguous`() async throws {
        let fixture = VerifyStateFixture()
        let incomplete = fixture.result(
            elements: [
                fixture.element(identifier: "duplicate", label: "First", value: "Expected"),
                fixture.element(identifier: "duplicate", label: "Second", value: "Expected"),
            ],
            truncationInfo: DetectionTruncationInfo(incompleteAccessibilityRead: true),
            warnings: ["ax_incomplete_read"])
        let context = await fixture.context(results: [incomplete])

        let response = try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [[
                "kind": "element_value",
                "selector": ["identifier": "duplicate"],
                "expected_value": "Expected",
            ]],
            "timeout_ms": 100,
            "stable_samples": 1,
        ]))

        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.stringMeta("reason", response)?.contains("ambiguous") == true)
        #expect(Self.intMeta("stable_samples", response) == 0)
    }

    @Test
    func `Incomplete direct value evidence cannot survive exact window drift`() async throws {
        let fixture = VerifyStateFixture()
        let incomplete = fixture.result(
            elements: [fixture.element(identifier: "basic-text-field", label: "Text", value: "Expected")],
            truncationInfo: DetectionTruncationInfo(incompleteAccessibilityRead: true),
            warnings: ["ax_incomplete_read"])
        let context = await fixture.context(results: [incomplete])
        let initial = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: fixture.window.bounds)
        let moved = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: fixture.window.bounds.offsetBy(dx: 1, dy: 0))
        let windows = LockedSystemWindowIdentitySequence([initial, moved])
        let tool = fixture.tool(context: context, windowIdentityProvider: { _ in windows.next() })

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [[
                "kind": "element_value",
                "selector": ["identifier": "basic-text-field"],
                "expected_value": "Expected",
            ]],
            "timeout_ms": 100,
            "stable_samples": 1,
        ]))

        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.stringMeta("reason", response)?.contains("bounds changed") == true)
        #expect(Self.intMeta("stable_samples", response) == 0)
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
}
