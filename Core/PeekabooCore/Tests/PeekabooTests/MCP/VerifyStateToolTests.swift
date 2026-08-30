import CoreGraphics
import Foundation
import MCP
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable @_spi(Testing) import PeekabooAutomationKit

@Suite(.serialized)
@MainActor
struct VerifyStateToolTests {
    @Test
    func `Public schema documents structured predicate object variants`() async {
        let fixture = VerifyStateFixture()
        let context = await fixture.context(results: [])

        guard case let .object(schema) = fixture.tool(context: context).inputSchema,
              case let .object(properties)? = schema["properties"],
              case let .object(predicates)? = properties["predicates"],
              case let .object(items)? = predicates["items"],
              case let .array(variants)? = items["oneOf"],
              case let .string(description)? = items["description"]
        else {
            Issue.record("verify_state predicate schema is missing")
            return
        }

        #expect(variants.count == 6)
        #expect(variants.allSatisfy { variant in
            guard case let .object(variantSchema) = variant,
                  case let .string(type)? = variantSchema["type"]
            else { return false }
            return type == "object"
        })
        #expect(description.contains(#"{"kind":"window_exists","expected":true}"#))
        #expect(description.contains(#"{"kind":"element_value""#))
    }

    @Test
    func `Prose predicate formats return the supported structured shape`() async throws {
        let fixture = VerifyStateFixture()
        let context = await fixture.context(results: [])
        let malformedPredicates = [
            ["window id is 2887", "element with identifier basic-text-field has value Ready"],
            ["identifier=basic-text-field value=Ready"],
            [#"AXIdentifier == "basic-text-field" AND AXValue == "Ready""#],
        ]

        for predicates in malformedPredicates {
            let response = try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: [
                "pid": Int(fixture.application.processIdentifier),
                "window_id": fixture.window.windowID,
                "predicates": predicates,
            ]))

            #expect(response.isError)
            guard case let .text(text, _, _)? = response.content.first else {
                Issue.record("Expected verify_state error text")
                continue
            }
            #expect(text.contains("array of structured JSON objects"))
            #expect(text.contains(#"{"kind":"element_value""#))
            #expect(!text.contains("isn’t in the correct format"))
        }
    }

    @Test
    func `Verifier requires two fresh identical satisfied samples by default`() async throws {
        let fixture = await MainActor.run { VerifyStateFixture() }
        let context = await fixture.context(results: [fixture.satisfiedResult, fixture.satisfiedResult])

        let response = try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [
                ["kind": "window_exists", "expected": true],
                [
                    "kind": "element_value",
                    "selector": ["identifier": "document-content"],
                    "expected_value": "Ready",
                ],
                [
                    "kind": "element_enabled",
                    "selector": ["identifier": "document-content"],
                    "expected": true,
                ],
                [
                    "kind": "element_selected",
                    "selector": ["identifier": "ready-checkbox"],
                    "expected": true,
                ],
            ],
            "timeout_ms": 1000,
        ]))

        #expect(!response.isError)
        #expect(Self.stringMeta("status", response) == "satisfied")
        #expect(Self.intMeta("sample_count", response) == 2)
        #expect(Self.intMeta("stable_samples", response) == 2)
        let contexts = await MainActor.run { fixture.automation.contexts }
        #expect(contexts.count == 2)
        #expect(contexts.allSatisfy { $0.applicationProcessId == fixture.application.processIdentifier })
        #expect(contexts.allSatisfy { $0.windowID == fixture.window.windowID })
        #expect(contexts.allSatisfy { $0.requiresFreshAccessibilityTree == true })
        #expect(contexts.allSatisfy { ($0.accessibilityTimeoutSeconds ?? 0) <= 1 })
    }

    @Test
    func `Window title and index selectors participate in polling`() async throws {
        let fixture = VerifyStateFixture()
        let context = await fixture.context(results: [])
        let tool = fixture.tool(context: context)
        for selector in [["window_title": "rifi"], ["window_index": 0]] {
            var arguments: [String: Any] = selector
            arguments["pid"] = Int(fixture.application.processIdentifier)
            arguments["predicates"] = [["kind": "window_exists", "expected": true]]
            arguments["timeout_ms"] = 100
            arguments["stable_samples"] = 1
            let response = try await tool.execute(arguments: ToolArguments(raw: arguments))
            #expect(Self.stringMeta("status", response) == "satisfied")
        }

        let missing = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_title": "Not Created Yet",
            "predicates": [["kind": "window_exists", "expected": true]],
            "timeout_ms": 100,
            "stable_samples": 1,
        ]))
        #expect(Self.stringMeta("status", missing) == "unsatisfied")
        #expect(Self.stringMeta("reason", missing)?.contains("Not Created Yet") == true)
    }

    @Test
    func `Truncated accessibility cannot satisfy even a positive match`() async throws {
        let fixture = await MainActor.run { VerifyStateFixture() }
        let truncated = fixture.result(truncated: true)
        let context = await fixture.context(results: [truncated, truncated])

        let response = try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: [
            "app": #require(fixture.application.bundleIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [[
                "kind": "element_exists",
                "selector": ["identifier": "document-content"],
                "expected": true,
            ]],
            "timeout_ms": 100,
            "stable_samples": 1,
        ]))

        #expect(!response.isError)
        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.stringMeta("reason", response)?.contains("truncated") == true)
    }

    @Test
    func `Incomplete or truncated accessibility cannot satisfy negative element existence`() async throws {
        let fixture = VerifyStateFixture()
        let cases = [
            (DetectionTruncationInfo(incompleteAccessibilityRead: true), "incomplete"),
            (DetectionTruncationInfo(maxElementCountReached: true), "truncated"),
        ]
        for (truncationInfo, reason) in cases {
            let result = fixture.result(elements: [], truncationInfo: truncationInfo)
            let context = await fixture.context(results: [result])
            let response = try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: [
                "pid": Int(fixture.application.processIdentifier),
                "window_id": fixture.window.windowID,
                "predicates": [[
                    "kind": "element_exists",
                    "selector": ["identifier": "missing-from-partial-tree"],
                    "expected": false,
                ]],
                "timeout_ms": 100,
                "stable_samples": 1,
            ]))

            #expect(!response.isError)
            #expect(Self.stringMeta("status", response) == "unknown")
            #expect(Self.stringMeta("reason", response)?.contains(reason) == true)
        }
    }

    @Test
    func `Cached AX result is unknown when a fresh sample was required`() async throws {
        let fixture = VerifyStateFixture()
        let cached = fixture.result(method: "AXorcist (cached)")
        let context = await fixture.context(results: [cached])

        let response = try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "predicates": [[
                "kind": "element_exists",
                "selector": ["identifier": "document-content"],
                "expected": true,
            ]],
            "timeout_ms": 100,
            "stable_samples": 1,
        ]))

        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.stringMeta("reason", response)?.contains("not a fresh native AX traversal") == true)
    }

    @Test
    func `Unavailable AXEnabled cannot prove a false enabled predicate`() async throws {
        let fixture = VerifyStateFixture()
        let element = DetectedElement(
            id: "elem_unknown_enabled",
            type: .button,
            label: "Disabled",
            bounds: CGRect(x: 10, y: 10, width: 40, height: 20),
            isEnabled: false,
            attributes: ["identifier": "unknown-enabled", "role": "AXButton"])
        let context = await fixture.context(results: [fixture.result(elements: [element])])

        let response = try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "predicates": [[
                "kind": "element_enabled",
                "selector": ["identifier": "unknown-enabled"],
                "expected": false,
            ]],
            "timeout_ms": 100,
            "stable_samples": 1,
        ]))

        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.stringMeta("reason", response)?.contains("AXEnabled unavailable") == true)
    }

    @Test
    func `Missing target can stably prove negative existence without AX`() async throws {
        let fixture = await MainActor.run { VerifyStateFixture(includeApplication: false) }
        let context = await fixture.context(results: [])
        let tool = fixture.tool(context: context, processStartIdentityProvider: { _ in nil })

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "predicates": [
                ["kind": "window_exists", "expected": false],
                [
                    "kind": "element_exists",
                    "selector": ["label": "Never There"],
                    "expected": false,
                ],
            ],
            "timeout_ms": 500,
        ]))

        #expect(Self.stringMeta("status", response) == "satisfied")
        #expect(Self.intMeta("stable_samples", response) == 2)
        #expect(await MainActor.run { fixture.automation.contexts.isEmpty })
    }

    @Test
    func `Ambiguous state selector is unknown instead of choosing one match`() async throws {
        let fixture = await MainActor.run { VerifyStateFixture() }
        let ambiguous = fixture.result(elements: [
            fixture.element(identifier: "one", label: "Duplicate", value: "A"),
            fixture.element(identifier: "two", label: "Duplicate", value: "B"),
        ])
        let context = await fixture.context(results: [ambiguous])

        let response = try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "predicates": [[
                "kind": "element_value",
                "selector": ["label": "Duplicate"],
                "expected_value": "A",
            ]],
            "timeout_ms": 100,
            "stable_samples": 1,
        ]))

        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.stringMeta("reason", response)?.contains("ambiguous") == true)
    }

    @Test
    func `Role selector matches both AX role and normalized element type`() async throws {
        let fixture = VerifyStateFixture()
        let button = DetectedElement(
            id: "elem_dual_role",
            type: .button,
            label: "Continue",
            bounds: CGRect(x: 50, y: 70, width: 100, height: 30),
            isEnabled: true,
            attributes: ["identifier": "dual-role", "role": "AXButton"])
        let context = await fixture.context(results: [fixture.result(elements: [button])])
        let matchingArguments: [String: Any] = [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [[
                "kind": "element_exists",
                "selector": ["role": "button"],
                "expected": true,
            ]],
            "timeout_ms": 100,
            "stable_samples": 1,
        ]

        let matching = try await fixture.tool(context: context).execute(
            arguments: ToolArguments(raw: matchingArguments))
        #expect(Self.stringMeta("status", matching) == "satisfied")

        var negativeArguments = matchingArguments
        negativeArguments["predicates"] = [[
            "kind": "element_exists",
            "selector": ["role": "button"],
            "expected": false,
        ]]
        let negative = try await fixture.tool(context: context).execute(
            arguments: ToolArguments(raw: negativeArguments))
        #expect(Self.stringMeta("status", negative) == "unsatisfied")
    }

    @Test
    func `Window move during AX traversal is unknown even with one stable sample`() async throws {
        let fixture = VerifyStateFixture()
        let context = await fixture.context(results: [fixture.satisfiedResult])
        let initial = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: fixture.window.bounds)
        let moved = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: fixture.window.bounds.offsetBy(dx: 50, dy: 25))
        let windows = LockedSystemWindowIdentitySequence([initial, moved])
        let tool = fixture.tool(
            context: context,
            windowIdentityProvider: { _ in windows.next() })

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [[
                "kind": "element_exists",
                "selector": ["identifier": "document-content"],
                "expected": true,
            ]],
            "timeout_ms": 100,
            "stable_samples": 1,
        ]))

        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.stringMeta("reason", response)?.contains("bounds changed") == true)
        #expect(Self.intMeta("stable_samples", response) == 0)
    }

    @Test
    func `Window owner change during AX traversal is unknown with one stable sample`() async throws {
        let fixture = VerifyStateFixture()
        let context = await fixture.context(results: [fixture.satisfiedResult])
        let initial = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: fixture.window.bounds)
        let reused = fixture.systemWindowIdentity(
            ownerProcessIdentifier: 9001,
            bounds: fixture.window.bounds)
        let windows = LockedSystemWindowIdentitySequence([initial, reused])
        let tool = fixture.tool(
            context: context,
            windowIdentityProvider: { _ in windows.next() })

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [[
                "kind": "element_exists",
                "selector": ["identifier": "document-content"],
                "expected": true,
            ]],
            "timeout_ms": 100,
            "stable_samples": 1,
        ]))

        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.stringMeta("reason", response)?.contains("changed owner") == true)
        #expect(Self.intMeta("stable_samples", response) == 0)
    }

    @Test
    func `Bounds mismatch is a deterministic unsatisfied result`() async throws {
        let fixture = await MainActor.run { VerifyStateFixture() }
        let context = await fixture.context(results: [])

        let response = try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [[
                "kind": "window_bounds",
                "bounds": ["x": 1, "y": 2, "width": 3, "height": 4],
                "tolerance": 0,
            ]],
            "timeout_ms": 100,
            "stable_samples": 1,
        ]))

        #expect(Self.stringMeta("status", response) == "unsatisfied")
        #expect(await MainActor.run { fixture.automation.contexts.isEmpty })
    }

    @Test
    func `Non-exact window evaluates live geometry after inventory selection`() async throws {
        let fixture = VerifyStateFixture()
        let applications = VerifyStateApplicationService(
            applications: [fixture.application],
            windows: [fixture.window])
        let context = await MCPToolTestHelpers.makeContext(
            automation: fixture.automation,
            applications: applications)
        let liveBounds = CGRect(x: 140, y: 160, width: 900, height: 700)
        let liveWindow = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: liveBounds)
        let tool = fixture.tool(
            context: context,
            windowIdentityProvider: { _ in liveWindow })

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "predicates": [[
                "kind": "window_bounds",
                "bounds": [
                    "x": Double(fixture.window.bounds.origin.x),
                    "y": Double(fixture.window.bounds.origin.y),
                    "width": Double(fixture.window.bounds.width),
                    "height": Double(fixture.window.bounds.height),
                ],
                "tolerance": 0,
            ]],
            "timeout_ms": 100,
            "stable_samples": 1,
        ]))

        #expect(Self.stringMeta("status", response) == "unsatisfied")
        #expect(applications.listWindowsCallCount > 0)
        #expect(fixture.automation.contexts.isEmpty)
    }

    @Test
    func `Exact window ownership mismatch cannot fall through to a sibling window`() async throws {
        let fixture = VerifyStateFixture()
        let context = await fixture.context(results: [fixture.satisfiedResult])

        let response = try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID + 1,
            "predicates": [["kind": "window_exists", "expected": true]],
            "timeout_ms": 100,
            "stable_samples": 1,
        ]))

        #expect(Self.stringMeta("status", response) == "unsatisfied")
        #expect(fixture.automation.contexts.isEmpty)
    }

    @Test
    func `Foreign owner for an exact window is unknown rather than ordinary absence`() async throws {
        let fixture = VerifyStateFixture()
        let applications = VerifyStateApplicationService(
            applications: [fixture.application],
            windows: [fixture.window])
        let context = await MCPToolTestHelpers.makeContext(
            automation: fixture.automation,
            applications: applications)
        let tool = fixture.tool(
            context: context,
            windowOwnerProcessIdentifierProvider: { _ in 9001 })

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [["kind": "window_exists", "expected": true]],
            "timeout_ms": 100,
            "stable_samples": 1,
        ]))

        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.stringMeta("reason", response)?.contains("belongs to PID 9001") == true)
        #expect(applications.listWindowsCallCount == 0)
    }

    @Test
    func `WindowServer miss preserves exact minimized window found by complete inventory`() async throws {
        let fixture = VerifyStateFixture()
        let minimizedWindow = ServiceWindowInfo(
            windowID: fixture.window.windowID,
            title: fixture.window.title,
            bounds: fixture.window.bounds,
            isMinimized: true,
            isMainWindow: true,
            isOffScreen: true,
            isOnScreen: false)
        let applications = VerifyStateApplicationService(
            applications: [fixture.application],
            windows: [minimizedWindow])
        let context = await MCPToolTestHelpers.makeContext(
            automation: fixture.automation,
            applications: applications)
        let tool = fixture.tool(
            context: context,
            windowOwnerProcessIdentifierProvider: { _ in nil })

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [["kind": "window_exists", "expected": true]],
            "timeout_ms": 250,
        ]))

        #expect(Self.stringMeta("status", response) == "satisfied")
        #expect(Self.intMeta("window_id", response) == fixture.window.windowID)
        #expect(Self.intMeta("stable_samples", response) == 2)
        #expect(applications.listWindowsCallCount == 2)
    }

    @Test(arguments: [false, true])
    func `PID reuse between polls never contributes a stable satisfied sample`(
        enumerationReportsReplacement: Bool) async throws
    {
        let fixture = VerifyStateFixture()
        let initial = ServiceApplicationInfo(
            processIdentifier: fixture.application.processIdentifier,
            processStartIdentity: 11,
            bundleIdentifier: fixture.application.bundleIdentifier,
            name: fixture.application.name,
            windowCount: 1)
        let replacement = ServiceApplicationInfo(
            processIdentifier: initial.processIdentifier,
            processStartIdentity: 22,
            bundleIdentifier: initial.bundleIdentifier,
            name: initial.name,
            windowCount: 1)
        let identities = LockedProcessIdentityMap([initial.processIdentifier: 11])
        let applications = VerifyStateApplicationService(
            applications: [initial],
            windows: [fixture.window],
            applicationLists: [[initial], [enumerationReportsReplacement ? replacement : initial]],
            onListApplications: { callCount in
                // Reuse belongs to the second poll, independent of identity probe count.
                if callCount == 2 {
                    identities.set(22, for: initial.processIdentifier)
                }
            })
        let context = await MCPToolTestHelpers.makeContext(
            automation: fixture.automation,
            applications: applications)
        let windows = LockedSystemWindowIdentitySequence([
            fixture.systemWindowIdentity(
                ownerProcessIdentifier: initial.processIdentifier,
                bounds: fixture.window.bounds),
        ])
        let tool = fixture.tool(
            context: context,
            processStartIdentityProvider: identities.identity(for:),
            windowIdentityProvider: { _ in windows.next() })

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [["kind": "window_exists", "expected": true]],
            "timeout_ms": 500,
        ]))

        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.stringMeta("reason", response)?.contains("changed process identity") == true)
        #expect(Self.intMeta("stable_samples", response) == 0)
        #expect(Self.intMeta("required_stable_samples", response) == 2)
        #expect(try #require(Self.intMeta("sample_count", response)) >= 2)
        #expect(applications.listApplicationsCallCount >= 2)
        #expect(identities.identity(for: initial.processIdentifier) == 22)
        // The same numeric window would satisfy the predicate if the new process slipped through.
        #expect(windows.callCount == 1)
        #expect(applications.listWindowsCallCount == 0)
        #expect(fixture.automation.contexts.isEmpty)
        Self.expectUnknownWindowPredicate(response, expected: true)
    }

    @Test
    func `PID reuse after application list receipt cannot pin explicit target`() async throws {
        let fixture = VerifyStateFixture()
        let enumerated = ServiceApplicationInfo(
            processIdentifier: fixture.application.processIdentifier,
            processStartIdentity: 11,
            bundleIdentifier: fixture.application.bundleIdentifier,
            name: fixture.application.name,
            windowCount: 1)
        let applications = VerifyStateApplicationService(
            applications: [enumerated],
            windows: [fixture.window])
        let context = await MCPToolTestHelpers.makeContext(
            automation: fixture.automation,
            applications: applications)
        let identities = LockedIdentitySequence([11, 22])
        let tool = fixture.tool(
            context: context,
            processStartIdentityProvider: { _ in identities.next() })

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [["kind": "window_exists", "expected": true]],
            "timeout_ms": 100,
            "stable_samples": 1,
        ]))

        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.stringMeta("reason", response)?.contains("after application enumeration") == true)
        #expect(Self.intMeta("stable_samples", response) == 0)
        #expect(fixture.automation.contexts.isEmpty)
    }

    @Test
    func `PID reuse before missing application cannot prove window absence`() async throws {
        let fixture = VerifyStateFixture()
        let initial = ServiceApplicationInfo(
            processIdentifier: fixture.application.processIdentifier,
            processStartIdentity: 11,
            bundleIdentifier: fixture.application.bundleIdentifier,
            name: fixture.application.name,
            windowCount: 1)
        let identities = LockedProcessIdentityMap([initial.processIdentifier: 11])
        let applications = VerifyStateApplicationService(
            applications: [initial],
            windows: [fixture.window],
            applicationLists: [[initial], []],
            onListApplications: { callCount in
                if callCount == 2 {
                    identities.set(22, for: initial.processIdentifier)
                }
            })
        let context = await MCPToolTestHelpers.makeContext(
            automation: fixture.automation,
            applications: applications)
        let windows = LockedSystemWindowIdentitySequence([
            fixture.systemWindowIdentity(
                ownerProcessIdentifier: initial.processIdentifier,
                bounds: fixture.window.bounds),
        ])
        let tool = fixture.tool(
            context: context,
            processStartIdentityProvider: identities.identity(for:),
            windowIdentityProvider: { _ in windows.next() })

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [["kind": "window_exists", "expected": false]],
            "timeout_ms": 500,
            "stable_samples": 1,
        ]))

        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.stringMeta("reason", response)?.contains("before absence") == true)
        #expect(Self.intMeta("stable_samples", response) == 0)
        #expect(try #require(Self.intMeta("sample_count", response)) >= 2)
        #expect(applications.listApplicationsCallCount >= 2)
        #expect(identities.identity(for: initial.processIdentifier) == 22)
        #expect(windows.callCount == 1)
        #expect(applications.listWindowsCallCount == 0)
        #expect(fixture.automation.contexts.isEmpty)
        Self.expectUnknownWindowPredicate(response, expected: false)
    }

    @Test
    func `Exact window ID reused by the target process remains unknown`() async throws {
        let fixture = VerifyStateFixture()
        let windows = LockedSystemWindowIdentitySequence([
            fixture.systemWindowIdentity(ownerProcessIdentifier: 9001, bounds: fixture.window.bounds),
            fixture.systemWindowIdentity(
                ownerProcessIdentifier: fixture.application.processIdentifier,
                bounds: fixture.window.bounds),
        ])
        let applications = VerifyStateApplicationService(
            applications: [fixture.application],
            windows: [fixture.window],
            onListApplications: { callCount in
                if callCount == 2 {
                    #expect(windows.callCount == 1)
                }
            })
        let context = await MCPToolTestHelpers.makeContext(
            automation: fixture.automation,
            applications: applications)
        let tool = fixture.tool(
            context: context,
            windowIdentityProvider: { _ in windows.next() })

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [["kind": "window_exists", "expected": true]],
            // The reuse observation needs a second 100 ms poll, including executor/actor hops.
            "timeout_ms": 500,
            "stable_samples": 1,
        ]))

        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.stringMeta("reason", response)?.contains("changed owner") == true)
        #expect(Self.stringMeta("reason", response)?.contains("PID 9001, not target PID 4242") == true)
        #expect(Self.intMeta("stable_samples", response) == 0)
        #expect(Self.intMeta("required_stable_samples", response) == 1)
        #expect(try #require(Self.intMeta("sample_count", response)) >= 2)
        #expect(applications.listApplicationsCallCount >= 2)
        // Prove the target-owned replacement was read, not just the initial foreign owner.
        #expect(windows.callCount >= 2)
        #expect(applications.listWindowsCallCount == 0)
        #expect(fixture.automation.contexts.isEmpty)
        Self.expectUnknownWindowPredicate(response, expected: true)
    }
}

extension VerifyStateToolTests {
    @Test
    func `App selectors reject a new PID and reused pinned PID`() {
        let identities = LockedProcessIdentityMap([4242: 11, 4343: 22])
        let tracker = VerifyStateTargetIdentityTracker(
            target: .application("com.test.VerifyState"),
            processStartIdentityProvider: identities.identity(for:))
        let first = ServiceApplicationInfo(
            processIdentifier: 4242,
            processStartIdentity: 11,
            bundleIdentifier: "com.test.VerifyState",
            name: "Verify State Test")
        let relaunched = ServiceApplicationInfo(
            processIdentifier: 4343,
            processStartIdentity: 22,
            bundleIdentifier: "com.test.VerifyState",
            name: "Verify State Test")

        guard case .resolved = tracker.resolve(first) else {
            Issue.record("Initial app process should resolve")
            return
        }
        guard case let .unknown(relaunchReason) = tracker.resolve(relaunched) else {
            Issue.record("An app selector must remain pinned to its first PID")
            return
        }
        #expect(relaunchReason.contains("pinned PID 4242"))
        identities.set(33, for: 4242)
        guard case let .unknown(reason) = tracker.resolve(first) else {
            Issue.record("A previously observed numeric PID must not be silently reused")
            return
        }
        #expect(reason.contains("changed process identity"))
    }

    @Test
    func `App selector PID swap cannot complete stable verification`() async throws {
        let fixture = VerifyStateFixture()
        let initial = ServiceApplicationInfo(
            processIdentifier: fixture.application.processIdentifier,
            processStartIdentity: 11,
            bundleIdentifier: fixture.application.bundleIdentifier,
            name: fixture.application.name,
            windowCount: 1)
        let relaunched = ServiceApplicationInfo(
            processIdentifier: 4343,
            processStartIdentity: 22,
            bundleIdentifier: fixture.application.bundleIdentifier,
            name: fixture.application.name,
            windowCount: 1)
        let identities = LockedProcessIdentityMap([initial.processIdentifier: 11])
        let windows = LockedSystemWindowIdentitySequence([
            fixture.systemWindowIdentity(
                ownerProcessIdentifier: initial.processIdentifier,
                bounds: fixture.window.bounds),
        ])
        let applications = VerifyStateApplicationService(
            applications: [initial, relaunched],
            windows: [fixture.window],
            applicationLists: [[initial], [relaunched]],
            onListApplications: { callCount in
                if callCount == 2 {
                    #expect(windows.callCount == 1)
                    identities.set(22, for: relaunched.processIdentifier)
                }
            })
        let context = await MCPToolTestHelpers.makeContext(
            automation: fixture.automation,
            applications: applications)
        let tool = fixture.tool(
            context: context,
            processStartIdentityProvider: identities.identity(for:),
            windowIdentityProvider: { _ in windows.next() })

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "app": #require(fixture.application.bundleIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [["kind": "window_exists", "expected": true]],
            // Leave bounded room after the 100 ms poll interval to record the rejected swap.
            "timeout_ms": 500,
        ]))

        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.stringMeta("reason", response)?.contains("pinned PID 4242") == true)
        #expect(Self.stringMeta("reason", response)?.contains("to PID 4343") == true)
        #expect(Self.intMeta("stable_samples", response) == 0)
        #expect(Self.intMeta("required_stable_samples", response) == 2)
        #expect(try #require(Self.intMeta("sample_count", response)) >= 2)
        #expect(applications.listApplicationsCallCount >= 2)
        #expect(identities.identity(for: initial.processIdentifier) == 11)
        #expect(identities.identity(for: relaunched.processIdentifier) == 22)
        // Selector drift must be rejected before observing any replacement window.
        #expect(windows.callCount == 1)
        #expect(applications.listWindowsCallCount == 0)
        #expect(fixture.automation.contexts.isEmpty)
        Self.expectUnknownWindowPredicate(response, expected: true)
    }

    @Test
    func `Partial window enumeration makes negative predicates unknown`() async throws {
        let fixture = VerifyStateFixture()
        let partialApplications = VerifyStateApplicationService(
            applications: [fixture.application],
            windows: [],
            windowStatus: .partial,
            warnings: ["AX window enumeration timed out"])
        let context = await MCPToolTestHelpers.makeContext(
            automation: fixture.automation,
            applications: partialApplications)

        let response = try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "predicates": [["kind": "window_exists", "expected": false]],
            "timeout_ms": 100,
            "stable_samples": 1,
        ]))

        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.stringMeta("reason", response)?.contains("incomplete") == true)
    }

    @Test
    func `Partial application enumeration makes missing PID unknown`() async throws {
        let fixture = VerifyStateFixture()
        let partialApplications = VerifyStateApplicationService(
            applications: [],
            windows: [],
            applicationStatus: .partial,
            applicationWarnings: ["Workspace enumeration interrupted"])
        let context = await MCPToolTestHelpers.makeContext(
            automation: fixture.automation,
            applications: partialApplications)

        let response = try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "predicates": [["kind": "window_exists", "expected": false]],
            "timeout_ms": 100,
            "stable_samples": 1,
        ]))

        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.stringMeta("reason", response)?.contains("Application enumeration was incomplete") == true)
    }

    @Test
    func `Optional final screenshot is silent and exact-window scoped`() async throws {
        let fixture = VerifyStateFixture()
        let capture = VerifyStateScreenCaptureService(
            applicationInfo: fixture.application,
            windowInfo: fixture.window)
        let context = await fixture.context(results: [], screenCapture: capture)

        let response = try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [["kind": "window_exists", "expected": true]],
            "timeout_ms": 100,
            "stable_samples": 1,
            "final_screenshot": true,
        ]))

        #expect(Self.stringMeta("status", response) == "satisfied")
        #expect(capture.windowIDs == [CGWindowID(fixture.window.windowID)])
        #expect(capture.visualizerModes == [.none])
        #expect(response.content.contains { content in
            if case .image = content {
                return true
            }
            return false
        })
    }

    @Test
    func `Changed same owner receipt before final screenshot makes verification unknown`() async throws {
        let fixture = VerifyStateFixture()
        let capture = VerifyStateScreenCaptureService(
            applicationInfo: fixture.application,
            windowInfo: fixture.window)
        let context = await fixture.context(results: [], screenCapture: capture)
        let initial = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: fixture.window.bounds)
        let replacement = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: fixture.window.bounds.offsetBy(dx: 1, dy: 0))
        let windows = LockedSystemWindowIdentitySequence([initial, replacement])
        let tool = fixture.tool(
            context: context,
            windowIdentityProvider: { _ in windows.next() })

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [["kind": "window_exists", "expected": true]],
            "timeout_ms": 500,
            "stable_samples": 1,
            "final_screenshot": true,
        ]))

        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.intMeta("stable_samples", response) == 0)
        #expect(Self.boolMeta("screenshot_attached", response) == false)
        #expect(Self.stringMeta("screenshot_error", response)?.contains("verification receipt changed") == true)
        #expect(capture.windowIDs.isEmpty)
    }

    @Test
    func `Changed receipt after final screenshot discards image and makes result unknown`() async throws {
        let fixture = VerifyStateFixture()
        let capture = VerifyStateScreenCaptureService(
            applicationInfo: fixture.application,
            windowInfo: fixture.window)
        let context = await fixture.context(results: [], screenCapture: capture)
        let initial = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: fixture.window.bounds)
        let replacement = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: fixture.window.bounds.offsetBy(dx: 0, dy: 1))
        let windows = LockedSystemWindowIdentitySequence([initial, initial, replacement])
        let tool = fixture.tool(
            context: context,
            windowIdentityProvider: { _ in windows.next() })

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [["kind": "window_exists", "expected": true]],
            "timeout_ms": 500,
            "stable_samples": 1,
            "final_screenshot": true,
        ]))

        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.intMeta("stable_samples", response) == 0)
        #expect(Self.boolMeta("screenshot_attached", response) == false)
        #expect(Self.stringMeta("screenshot_error", response)?.contains("verification receipt changed") == true)
        #expect(capture.windowIDs == [CGWindowID(fixture.window.windowID)])
        #expect(!response.content.contains { content in
            if case .image = content {
                return true
            }
            return false
        })
    }

    @Test
    func `Capture metadata owner mismatch discards a reused exact window screenshot`() async throws {
        let fixture = VerifyStateFixture()
        let foreignApplication = ServiceApplicationInfo(
            processIdentifier: 9001,
            bundleIdentifier: "com.test.Foreign",
            name: "Foreign",
            windowCount: 1)
        let capture = VerifyStateScreenCaptureService(
            applicationInfo: foreignApplication,
            windowInfo: fixture.window)
        let context = await fixture.context(results: [], screenCapture: capture)

        let response = try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [["kind": "window_exists", "expected": true]],
            "timeout_ms": 500,
            "stable_samples": 1,
            "final_screenshot": true,
        ]))

        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.intMeta("stable_samples", response) == 0)
        #expect(Self.boolMeta("screenshot_attached", response) == false)
        #expect(Self.stringMeta("screenshot_error", response)?.contains("metadata") == true)
        #expect(!response.content.contains { content in
            if case .image = content {
                return true
            }
            return false
        })
    }

    @Test
    func `Window owner reuse during capture discards otherwise matching screenshot metadata`() async throws {
        let fixture = VerifyStateFixture()
        let capture = VerifyStateScreenCaptureService(
            applicationInfo: fixture.application,
            windowInfo: fixture.window)
        let context = await fixture.context(results: [], screenCapture: capture)
        let owners = LockedWindowOwnerSequence([4242, 4242, 9001])
        let tool = fixture.tool(
            context: context,
            windowOwnerProcessIdentifierProvider: { _ in owners.next() })

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [["kind": "window_exists", "expected": true]],
            "timeout_ms": 500,
            "stable_samples": 1,
            "final_screenshot": true,
        ]))

        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.intMeta("stable_samples", response) == 0)
        #expect(Self.boolMeta("screenshot_attached", response) == false)
        #expect(Self.stringMeta("screenshot_error", response)?.contains("changed owner") == true)
        #expect(!response.content.contains { content in
            if case .image = content {
                return true
            }
            return false
        })
    }

    @Test
    func `Hard deadline returns while noncooperative window enumeration is still pending`() async throws {
        let fixture = VerifyStateFixture()
        let slowApplications = VerifyStateApplicationService(
            applications: [fixture.application],
            windows: [fixture.window],
            delay: .seconds(1))
        let context = await MCPToolTestHelpers.makeContext(
            automation: fixture.automation,
            applications: slowApplications)
        let clock = ContinuousClock()
        let start = clock.now

        let response = try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "predicates": [["kind": "window_exists", "expected": true]],
            "timeout_ms": 100,
            "stable_samples": 1,
        ]))

        #expect(start.duration(to: clock.now) < .milliseconds(500))
        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.stringMeta("reason", response)?.contains("deadline") == true)
    }

    @Test
    func `Slow optional screenshot is omitted without losing a satisfied state result`() async throws {
        let fixture = VerifyStateFixture()
        let capture = VerifyStateScreenCaptureService(
            applicationInfo: fixture.application,
            windowInfo: fixture.window,
            delay: .seconds(1))
        let context = await fixture.context(results: [], screenCapture: capture)
        let clock = ContinuousClock()
        let start = clock.now

        let response = try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "predicates": [["kind": "window_exists", "expected": true]],
            "timeout_ms": 100,
            "stable_samples": 1,
            "final_screenshot": true,
        ]))

        #expect(start.duration(to: clock.now) < .milliseconds(500))
        #expect(Self.stringMeta("status", response) == "satisfied")
        #expect(Self.boolMeta("screenshot_attached", response) == false)
        #expect(Self.stringMeta("screenshot_error", response)?.contains("deadline") == true)
        #expect(!response.content.contains { content in
            if case .image = content {
                return true
            }
            return false
        })
    }

    @Test
    func `Hard deadline returns while noncooperative AX inspection is still pending`() async throws {
        let fixture = VerifyStateFixture()
        fixture.automation.delay = .seconds(1)
        let context = await fixture.context(results: [fixture.satisfiedResult])
        let clock = ContinuousClock()
        let start = clock.now

        let response = try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "predicates": [[
                "kind": "element_exists",
                "selector": ["identifier": "document-content"],
                "expected": true,
            ]],
            "timeout_ms": 100,
            "stable_samples": 1,
        ]))

        #expect(start.duration(to: clock.now) < .milliseconds(500))
        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.stringMeta("reason", response)?.contains("deadline") == true)
    }

    @Test
    func `Deadline runner keeps MainActor heartbeat responsive during a synchronous block`() async throws {
        let heartbeat = VerifyStateHeartbeatProbe()
        let heartbeatTask = Task { @MainActor in
            while !Task.isCancelled {
                heartbeat.count += 1
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        defer { heartbeatTask.cancel() }
        try await Task.sleep(for: .milliseconds(10))
        let heartbeatBefore = heartbeat.count
        let clock = ContinuousClock()
        let startedAt = clock.now

        do {
            _ = try await VerifyStateDeadlineRunner.run(seconds: 0.05) {
                blockCurrentThread(seconds: 0.2)
                return true
            }
            Issue.record("Expected the detached deadline to win")
        } catch VerifyStateDeadlineError.timedOut {
            // Expected.
        }

        #expect(startedAt.duration(to: clock.now) < .milliseconds(150))
        #expect(heartbeat.count > heartbeatBefore)
    }

    @Test
    func `Verifier timeout survives synchronous exact window sampling block`() async throws {
        let fixture = VerifyStateFixture()
        let context = await fixture.context(results: [])
        let targetProcessIdentifier = fixture.application.processIdentifier
        let tool = fixture.tool(
            context: context,
            windowOwnerProcessIdentifierProvider: { _ in
                blockCurrentThread(seconds: 0.2)
                return pid_t(targetProcessIdentifier)
            })
        let request = VerifyStateRequest(
            target: .pid(targetProcessIdentifier),
            windowID: CGWindowID(fixture.window.windowID),
            predicates: [.windowExists(true)],
            timeoutMilliseconds: 50,
            stableSamples: 1,
            finalScreenshot: false)
        let heartbeat = VerifyStateHeartbeatProbe()
        let heartbeatTask = Task { @MainActor in
            while !Task.isCancelled {
                heartbeat.count += 1
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        defer { heartbeatTask.cancel() }
        try await Task.sleep(for: .milliseconds(10))
        let heartbeatBefore = heartbeat.count
        let clock = ContinuousClock()
        let startedAt = clock.now

        let response = try await tool.verify(request)

        #expect(startedAt.duration(to: clock.now) < .milliseconds(150))
        #expect(heartbeat.count > heartbeatBefore)
        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.intMeta("sample_count", response) == 0)
        #expect(Self.intMeta("stable_samples", response) == 0)
        #expect(Self.stringMeta("reason", response)?.contains("deadline") == true)
    }

    @Test
    func `Satisfied sample completing after deadline cannot become terminal success`() async throws {
        let fixture = VerifyStateFixture()
        fixture.automation.blockingDelaySeconds = 0.15
        let context = await fixture.context(results: [fixture.satisfiedResult])
        let clock = ContinuousClock()
        let start = clock.now

        let response = try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [[
                "kind": "element_exists",
                "selector": ["identifier": "document-content"],
                "expected": true,
            ]],
            "timeout_ms": 100,
            "stable_samples": 1,
        ]))

        #expect(start.duration(to: clock.now) < .milliseconds(500))
        #expect(Self.stringMeta("status", response) == "unknown")
        #expect(Self.intMeta("sample_count", response) == 0)
        #expect(Self.intMeta("stable_samples", response) == 0)
        #expect(Self.stringMeta("reason", response)?.contains("deadline") == true)
    }

    @Test
    func `Cancellation returns while noncooperative enumeration remains pending`() async throws {
        let fixture = VerifyStateFixture()
        let slowApplications = VerifyStateApplicationService(
            applications: [fixture.application],
            windows: [fixture.window],
            delay: .seconds(1))
        let context = await MCPToolTestHelpers.makeContext(
            automation: fixture.automation,
            applications: slowApplications)
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task { @MainActor in
            try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: [
                "pid": Int(fixture.application.processIdentifier),
                "predicates": [["kind": "window_exists", "expected": true]],
                "timeout_ms": 10000,
                "stable_samples": 1,
            ]))
        }

        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(start.duration(to: clock.now) < .milliseconds(500))
    }

    @Test
    func `Verifier waits behind the global snapshot mutation boundary`() async throws {
        let fixture = VerifyStateFixture()
        let gate = MCPToolSnapshotExecutionGate()
        try await gate.acquire()
        let context = await fixture.context(
            results: [fixture.satisfiedResult],
            snapshotExecutionGate: gate)
        let arguments = ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "predicates": [[
                "kind": "element_exists",
                "selector": ["identifier": "document-content"],
                "expected": true,
            ]],
            "timeout_ms": 500,
            "stable_samples": 1,
        ])

        let task = Task { @MainActor in
            try await context.execute(tool: fixture.tool(context: context), arguments: arguments)
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.automation.contexts.isEmpty)
        await gate.release()

        let response = try await task.value
        #expect(Self.stringMeta("status", response) == "satisfied")
        #expect(MCPToolSnapshotMutationPolicy.effect(
            toolName: "verify_state",
            arguments: arguments) == .freshObservation)
    }

    @Test
    func `Request validation enforces exact targets predicate bounds and hard cap`() async throws {
        let fixture = await MainActor.run { VerifyStateFixture() }
        let context = await fixture.context(results: [])
        let tool = fixture.tool(context: context)

        let noTarget = try await tool.execute(arguments: ToolArguments(raw: [
            "predicates": [["kind": "window_exists", "expected": true]],
        ]))
        #expect(noTarget.isError)

        let twoTargets = try await tool.execute(arguments: ToolArguments(raw: [
            "app": "TextEdit",
            "pid": 42,
            "predicates": [["kind": "window_exists", "expected": true]],
        ]))
        #expect(twoTargets.isError)

        let overCap = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": 42,
            "predicates": [["kind": "window_exists", "expected": true]],
            "timeout_ms": 10001,
        ]))
        #expect(overCap.isError)

        let oversizedWindowID = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": 42,
            "window_id": Int(UInt32.max) + 1,
            "predicates": [["kind": "window_exists", "expected": true]],
        ]))
        #expect(oversizedWindowID.isError)

        let conflictingWindows = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": 42,
            "window_id": 1,
            "window_title": "Dialog",
            "predicates": [["kind": "window_exists", "expected": true]],
        ]))
        #expect(conflictingWindows.isError)
    }

    private static func expectUnknownWindowPredicate(_ response: ToolResponse, expected: Bool) {
        guard case let .object(metadata) = response.meta,
              case let .array(predicates)? = metadata["predicates"],
              case let .object(predicate)? = predicates.first
        else {
            Issue.record("Expected a structured window predicate result")
            return
        }
        #expect(predicates.count == 1)
        #expect(predicate["kind"] == .string("window_exists"))
        #expect(predicate["expected"] == .bool(expected))
        #expect(predicate["status"] == .string("unknown"))
        #expect(predicate["observed"] == nil)
        #expect(metadata["window_id"] == nil)
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

@MainActor
final class VerifyStateFixture {
    let application = ServiceApplicationInfo(
        processIdentifier: 4242,
        processStartIdentity: 1,
        bundleIdentifier: "com.test.VerifyState",
        name: "Verify State Test",
        windowCount: 1)
    let window = ServiceWindowInfo(
        windowID: 707,
        title: "Verifier",
        bounds: CGRect(x: 40, y: 60, width: 800, height: 600),
        isMainWindow: true)
    fileprivate let automation = VerifyStateAutomationService()
    private let includeApplication: Bool

    init(includeApplication: Bool = true) {
        self.includeApplication = includeApplication
    }

    func systemWindowIdentity(
        ownerProcessIdentifier: pid_t,
        bounds: CGRect,
        title: String? = nil,
        isOnScreen: Bool? = nil) -> SystemWindowIdentity
    {
        SystemWindowIdentity(
            windowID: CGWindowID(self.window.windowID),
            ownerProcessIdentifier: ownerProcessIdentifier,
            title: title ?? self.window.title,
            bounds: bounds,
            layer: self.window.layer,
            alpha: self.window.alpha,
            isOnScreen: isOnScreen ?? self.window.isOnScreen,
            sharingState: self.window.sharingState)
    }

    func tool(
        context: MCPToolContext,
        processStartIdentityProvider: @escaping @Sendable (pid_t) -> UInt64? = { _ in 1 },
        windowOwnerProcessIdentifierProvider: @escaping @Sendable (CGWindowID) -> pid_t? = {
            $0 == 707 ? 4242 : nil
        },
        windowIdentityProvider: (@Sendable (CGWindowID) -> SystemWindowIdentity?)? = nil)
        -> VerifyStateTool
    {
        let window = self.window
        return VerifyStateTool(
            context: context,
            processStartIdentityProvider: processStartIdentityProvider,
            windowIdentityProvider: { windowID in
                if let windowIdentityProvider {
                    return windowIdentityProvider(windowID)
                }
                guard let owner = windowOwnerProcessIdentifierProvider(windowID) else { return nil }
                return SystemWindowIdentity(
                    windowID: windowID,
                    ownerProcessIdentifier: owner,
                    title: window.title,
                    bounds: window.bounds,
                    layer: window.layer,
                    alpha: window.alpha,
                    isOnScreen: window.isOnScreen,
                    sharingState: window.sharingState)
            })
    }

    var satisfiedResult: ElementDetectionResult {
        self.result(elements: self.defaultElements)
    }

    private var defaultElements: [DetectedElement] {
        [
            self.element(identifier: "document-content", label: "Document", value: "Ready"),
            DetectedElement(
                id: "elem_2",
                type: .checkbox,
                label: "Ready",
                bounds: CGRect(x: 60, y: 80, width: 20, height: 20),
                isEnabled: true,
                isSelected: true,
                attributes: ["identifier": "ready-checkbox", "role": "AXCheckBox"]),
        ]
    }

    func element(identifier: String, label: String, value: String) -> DetectedElement {
        DetectedElement(
            id: "elem_\(identifier)",
            type: .textField,
            label: label,
            value: value,
            bounds: CGRect(x: 50, y: 70, width: 300, height: 40),
            isEnabled: true,
            attributes: [
                "identifier": identifier,
                "role": "AXTextField",
                "axEnabledKnown": "true",
            ])
    }

    func result(
        elements: [DetectedElement]? = nil,
        truncated: Bool = false,
        truncationInfo: DetectionTruncationInfo? = nil,
        method: String = "AXorcist",
        warnings: [String] = []) -> ElementDetectionResult
    {
        let resolvedElements = elements ?? self.defaultElements
        return ElementDetectionResult(
            snapshotId: UUID().uuidString,
            screenshotPath: "",
            elements: ElementDetectionResultBuilder.group(resolvedElements),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: resolvedElements.count,
                method: method,
                warnings: warnings,
                windowContext: WindowContext(
                    applicationName: self.application.name,
                    applicationBundleId: self.application.bundleIdentifier,
                    applicationProcessId: self.application.processIdentifier,
                    windowTitle: self.window.title,
                    windowID: self.window.windowID,
                    windowBounds: self.window.bounds),
                truncationInfo: truncationInfo ?? (truncated
                    ? DetectionTruncationInfo(
                        maxDepthReached: true,
                        maxElementCountReached: false,
                        maxChildrenPerNodeReached: false)
                    : nil)))
    }

    func context(
        results: [ElementDetectionResult],
        screenCapture: (any ScreenCaptureServiceProtocol)? = nil,
        snapshotExecutionGate: MCPToolSnapshotExecutionGate = MCPToolSnapshotExecutionGate()) async -> MCPToolContext
    {
        self.automation.results = results
        let applications = VerifyStateApplicationService(
            applications: self.includeApplication ? [self.application] : [],
            windows: [self.window])
        return await MCPToolTestHelpers.makeContext(
            automation: self.automation,
            screenCapture: screenCapture,
            applications: applications,
            snapshotExecutionGate: snapshotExecutionGate)
    }
}

@MainActor
private final class VerifyStateHeartbeatProbe {
    var count = 0
}

private final class LockedIdentitySequence: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [UInt64]
    private var index = 0

    init(_ values: [UInt64]) {
        self.values = values
    }

    func next() -> UInt64? {
        self.lock.withLock {
            guard !self.values.isEmpty else { return nil }
            let value = self.values[min(self.index, self.values.count - 1)]
            self.index += 1
            return value
        }
    }
}

private final class LockedWindowOwnerSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [pid_t]
    private var index = 0

    init(_ values: [pid_t]) {
        self.values = values
    }

    func next() -> pid_t? {
        self.lock.withLock {
            guard !self.values.isEmpty else { return nil }
            let value = self.values[min(self.index, self.values.count - 1)]
            self.index += 1
            return value
        }
    }
}

final class LockedSystemWindowIdentitySequence: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [SystemWindowIdentity?]
    private var index = 0

    init(_ values: [SystemWindowIdentity?]) {
        self.values = values
    }

    var callCount: Int {
        self.lock.withLock { self.index }
    }

    func next() -> SystemWindowIdentity? {
        self.lock.withLock {
            guard !self.values.isEmpty else { return nil }
            let value = self.values[min(self.index, self.values.count - 1)]
            self.index += 1
            return value
        }
    }
}

private final class LockedProcessIdentityMap: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [pid_t: UInt64]

    init(_ values: [pid_t: UInt64]) {
        self.values = values
    }

    func identity(for processIdentifier: pid_t) -> UInt64? {
        self.lock.withLock { self.values[processIdentifier] }
    }

    func set(_ identity: UInt64, for processIdentifier: pid_t) {
        self.lock.withLock { self.values[processIdentifier] = identity }
    }
}

private func blockCurrentThread(seconds: TimeInterval) {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while ProcessInfo.processInfo.systemUptime < deadline {}
}

@MainActor
private final class VerifyStateAutomationService: MockAutomationService {
    var results: [ElementDetectionResult] = []
    var delay: Duration?
    var blockingDelaySeconds: TimeInterval?
    private(set) var contexts: [WindowContext] = []
    private var index = 0

    init() {
        super.init(accessibilityGranted: true)
    }

    override func inspectAccessibilityTree(windowContext: WindowContext?) async throws -> ElementDetectionResult {
        if let windowContext {
            self.contexts.append(windowContext)
        }
        if let delay {
            await verifyStateNonCooperativeDelay(delay)
        }
        if let blockingDelaySeconds {
            blockCurrentThread(seconds: blockingDelaySeconds)
        }
        guard !self.results.isEmpty else {
            throw PeekabooError.notImplemented("verify state test result")
        }
        let result = self.results[min(self.index, self.results.count - 1)]
        self.index += 1
        return result
    }
}
