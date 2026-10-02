import Foundation
import MCP
import PeekabooAutomationKit
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@Suite(.serialized)
@MainActor
struct VerifyStateTargetedPIDTests {
    @Test(arguments: ["", "Verifier"])
    func `unavailable native window titles do not constrain fresh AX verification`(nativeTitle: String) async throws {
        let fixture = VerifyStateFixture()
        let context = await fixture.context(results: [fixture.satisfiedResult, fixture.satisfiedResult])
        let nativeWindow = fixture.systemWindowIdentity(
            ownerProcessIdentifier: fixture.application.processIdentifier,
            bounds: fixture.window.bounds,
            title: nativeTitle)
        let tool = fixture.tool(context: context, windowIdentityProvider: { _ in nativeWindow })

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [[
                "kind": "element_value",
                "selector": ["identifier": "document-content"],
                "expected_value": "Ready",
            ]],
            "timeout_ms": 1000,
        ]))

        #expect(response.meta?.objectValue?["status"] == .string("satisfied"))
        #expect(response.meta?.objectValue?["stable_samples"] == .int(2))
        let contexts = fixture.inspectionContexts
        #expect(contexts.count == 2)
        for inspection in contexts {
            #expect(inspection.applicationProcessId == fixture.application.processIdentifier)
            #expect(inspection.applicationBundleId == fixture.application.bundleIdentifier)
            #expect(inspection.windowID == fixture.window.windowID)
            #expect(inspection.windowBounds == fixture.window.bounds)
            #expect(inspection.windowTitle == (nativeTitle.isEmpty ? nil : nativeTitle))
            #expect(inspection.shouldFocusWebContent == false)
            #expect(inspection.includeMenuBarElements == false)
            #expect(inspection.requiresFreshAccessibilityTree == true)
            #expect(inspection.allowApplicationScopedAccessibilityFallback != true)
        }
    }

    @Test(arguments: [UInt64(11), UInt64(22)])
    func `complete inventory cannot prove absence when pinned PID becomes readable again`(
        restoredGeneration: UInt64) async throws
    {
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
            applicationLists: [[]],
            onListApplications: { _ in identities.set(restoredGeneration, for: initial.processIdentifier) },
            applicationLookups: [initial, nil])
        let context = await fixture.context(results: [], applications: applications)
        let windows = LockedSystemWindowIdentitySequence([
            fixture.systemWindowIdentity(
                ownerProcessIdentifier: initial.processIdentifier,
                bounds: fixture.window.bounds),
        ])
        let tool = fixture.tool(
            context: context,
            processStartIdentityProvider: identities.identity(for:),
            windowIdentityProvider: { _ in
                let window = windows.next()
                identities.set(nil, for: initial.processIdentifier)
                return window
            })

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": Int(initial.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [["kind": "window_exists", "expected": false]],
            "timeout_ms": 500,
            "stable_samples": 1,
        ]))

        #expect(response.meta?.objectValue?["status"] == .string("unknown"))
        #expect(response.meta?.objectValue?["stable_samples"] == .int(0))
        #expect(applications.listApplicationsCallCount >= 1)
        #expect(applications.findApplicationIdentifiers.count >= 1)
        #expect(identities.identity(for: initial.processIdentifier) == restoredGeneration)
        #expect(windows.callCount == 1)
        #expect(fixture.inspectionContexts.isEmpty)
        #expect(response.meta?.objectValue?["window_id"] == nil)
    }

    @Test
    func `live PID polling ignores unrelated inventory failures without listing applications`() async throws {
        let fixture = VerifyStateFixture()
        let applications = VerifyStateApplicationService(
            applications: [fixture.application],
            windows: [fixture.window],
            applicationStatus: .partial,
            applicationWarnings: ["Unrelated process-generation identity was unavailable"])
        let context = await fixture.context(
            results: [fixture.satisfiedResult, fixture.satisfiedResult],
            applications: applications)
        let response = try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [[
                "kind": "element_value",
                "selector": ["identifier": "document-content"],
                "expected_value": "Ready",
            ]],
        ]))

        #expect(response.meta?.objectValue?["status"] == .string("satisfied"))
        #expect(response.meta?.objectValue?["stable_samples"] == .int(2))
        #expect(applications.findApplicationIdentifiers == Array(repeating: "PID:4242", count: 2))
        #expect(applications.listApplicationsCallCount == 0)
        #expect(applications.listWindowsCallCount == 0)
        #expect(fixture.inspectionContexts.count == 2)
    }

    @Test(arguments: ["wrong-pid", "missing-generation", "target-warning", "lookup-failure"])
    func `untrusted targeted lookup cannot prove positive or negative existence`(scenario: String) async throws {
        let fixture = VerifyStateFixture()
        let returned = ServiceApplicationInfo(
            processIdentifier: scenario == "wrong-pid" ? 4243 : fixture.application.processIdentifier,
            processStartIdentity: scenario == "missing-generation" ? nil : 1,
            bundleIdentifier: fixture.application.bundleIdentifier,
            name: fixture.application.name,
            windowCount: 1,
            metadataWarnings: scenario == "target-warning" ? ["Target metadata was incomplete"] : nil)
        for expected in [false, true] {
            let applications = VerifyStateApplicationService(
                applications: [fixture.application],
                windows: [fixture.window],
                applicationLookups: [scenario == "lookup-failure" ? nil : returned])
            let context = await fixture.context(results: [], applications: applications)
            let response = try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: [
                "pid": Int(fixture.application.processIdentifier),
                "window_id": fixture.window.windowID,
                "predicates": [["kind": "window_exists", "expected": expected]],
                "timeout_ms": 100,
                "stable_samples": 1,
            ]))

            #expect(response.meta?.objectValue?["status"] == .string("unknown"))
            #expect(applications.findApplicationIdentifiers == ["PID:4242"])
            #expect(applications.listApplicationsCallCount == 0)
            #expect(applications.listWindowsCallCount == 0)
            #expect(fixture.inspectionContexts.isEmpty)
        }
    }

    @Test
    func `named application still requires complete exact-match inventory`() async throws {
        let fixture = VerifyStateFixture()
        let applications = VerifyStateApplicationService(
            applications: [fixture.application],
            windows: [fixture.window],
            applicationStatus: .partial,
            applicationWarnings: ["Inventory incomplete"])
        let context = await fixture.context(results: [], applications: applications)
        let response = try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: [
            "app": fixture.application.name,
            "predicates": [["kind": "window_exists", "expected": true]],
            "timeout_ms": 100,
            "stable_samples": 1,
        ]))

        #expect(response.meta?.objectValue?["status"] == .string("unknown"))
        #expect(applications.findApplicationIdentifiers.isEmpty)
        #expect(applications.listApplicationsCallCount >= 1)
        #expect(fixture.inspectionContexts.isEmpty)
    }

    @Test
    func `targeted lookup remains inside the hard verification deadline`() async throws {
        let fixture = VerifyStateFixture()
        let applications = VerifyStateApplicationService(
            applications: [fixture.application],
            windows: [fixture.window],
            onFindApplication: { _ in await verifyStateNonCooperativeDelay(.milliseconds(200)) })
        let context = await fixture.context(results: [], applications: applications)
        let response = try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [["kind": "window_exists", "expected": true]],
            "timeout_ms": 100,
            "stable_samples": 1,
        ]))

        #expect(response.meta?.objectValue?["status"] == .string("unknown"))
        #expect(response.meta?.objectValue?["sample_count"] == .int(0))
        #expect(applications.findApplicationIdentifiers == ["PID:4242"])
        #expect(applications.listApplicationsCallCount == 0)
        #expect(fixture.inspectionContexts.isEmpty)
        await verifyStateNonCooperativeDelay(.milliseconds(150))
        #expect(fixture.inspectionContexts.isEmpty)
    }
}
