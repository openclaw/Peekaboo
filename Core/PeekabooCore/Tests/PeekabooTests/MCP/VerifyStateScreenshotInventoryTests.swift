import CoreGraphics
import MCP
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@Suite(.serialized)
@MainActor
struct VerifyStateScreenshotInventoryTests {
    @Test(arguments: [false, true])
    func `final screenshot does not repeat application inventory`(explicitPID: Bool) async throws {
        let fixture = VerifyStateFixture()
        let applications = VerifyStateApplicationService(
            applications: [fixture.application],
            windows: [fixture.window],
            applicationStatus: explicitPID ? .partial : .success,
            applicationWarnings: explicitPID ? ["Unrelated process metadata unavailable"] : [])
        let capture = VerifyStateScreenCaptureService(
            applicationInfo: fixture.application,
            windowInfo: fixture.window)
        let context = await fixture.context(results: [], screenCapture: capture, applications: applications)
        var arguments: [String: Any] = [
            "window_id": fixture.window.windowID,
            "predicates": [["kind": "window_exists", "expected": true]],
            "timeout_ms": 500,
            "stable_samples": 1,
            "final_screenshot": true,
        ]
        if explicitPID {
            arguments["pid"] = Int(fixture.application.processIdentifier)
        } else {
            arguments["app"] = fixture.application.name
        }

        let response = try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: arguments))
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["status"] == .string("satisfied"))
        #expect(metadata["screenshot_attached"] == .bool(true))
        #expect(metadata["sample_count"] == .int(1))
        #expect(applications.listApplicationsCallCount == (explicitPID ? 0 : 1))
        #expect(capture.windowIDs == [CGWindowID(fixture.window.windowID)])
        #expect(capture.visualizerModes == [.none])
        #expect(capture.permissionCheckCount == 0)
        #expect(response.content.contains {
            if case .image = $0 {
                true
            } else {
                false
            }
        })
    }

    @Test(arguments: [UInt64(2), nil])
    func `process change during final capture discards the screenshot`(
        replacementGeneration: UInt64?) async throws
    {
        let fixture = VerifyStateFixture()
        let pid = fixture.application.processIdentifier
        let identities = LockedProcessIdentityMap([pid: 1])
        let windows = LockedSystemWindowIdentitySequence([
            fixture.systemWindowIdentity(ownerProcessIdentifier: pid, bounds: fixture.window.bounds),
        ])
        let capture = VerifyStateScreenCaptureService(
            applicationInfo: fixture.application,
            windowInfo: fixture.window,
            onCapture: {
                await Task.yield()
                identities.set(replacementGeneration, for: pid)
            })
        let applications = VerifyStateApplicationService(applications: [fixture.application], windows: [fixture.window])
        let context = await fixture.context(results: [], screenCapture: capture, applications: applications)
        let tool = fixture.tool(
            context: context,
            processStartIdentityProvider: identities.identity(for:),
            windowIdentityProvider: { _ in windows.next() })

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "pid": Int(pid),
            "window_id": fixture.window.windowID,
            "predicates": [["kind": "window_exists", "expected": true]],
            "timeout_ms": 500,
            "stable_samples": 1,
            "final_screenshot": true,
        ]))

        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["status"] == .string("unknown"))
        #expect(metadata["stable_samples"] == .int(0))
        #expect(metadata["screenshot_attached"] == .bool(false))
        #expect(metadata["screenshot_error"]?.stringValue?.contains("process identity") == true)
        #expect(capture.permissionCheckCount == 0)
        #expect(capture.windowIDs == [CGWindowID(fixture.window.windowID)])
        #expect(windows.callCount == 3) // Sample, before capture, and after capture.
        #expect(applications.listApplicationsCallCount == 0)
        #expect(!response.content.contains {
            if case .image = $0 {
                true
            } else {
                false
            }
        })
    }

    @Test
    func `capture permission failure omits the optional image without losing satisfied predicates`() async throws {
        let fixture = VerifyStateFixture()
        let capture = VerifyStateScreenCaptureService(
            applicationInfo: fixture.application,
            windowInfo: fixture.window,
            onCapture: { throw PeekabooError.permissionDeniedScreenRecording })
        let context = await fixture.context(results: [], screenCapture: capture)
        let response = try await fixture.tool(context: context).execute(arguments: ToolArguments(raw: [
            "pid": Int(fixture.application.processIdentifier),
            "window_id": fixture.window.windowID,
            "predicates": [["kind": "window_exists", "expected": true]],
            "timeout_ms": 500,
            "stable_samples": 1,
            "final_screenshot": true,
        ]))
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["status"] == .string("satisfied"))
        #expect(metadata["stable_samples"] == .int(1))
        #expect(metadata["screenshot_attached"] == .bool(false))
        #expect(metadata["screenshot_error"]?.stringValue?.contains("Screen Recording") == true)
        #expect(capture.permissionCheckCount == 0)
        #expect(capture.windowIDs == [CGWindowID(fixture.window.windowID)])
        #expect(!response.content.contains {
            if case .image = $0 {
                true
            } else {
                false
            }
        })
    }
}
