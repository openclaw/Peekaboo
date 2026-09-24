import CoreGraphics
import Foundation
import PeekabooAutomationKit
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@Suite(.serialized)
struct ClickToolQueryWaitTests {
    @Test
    func `missing snapshot-local id does not wait`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let started = Date()
        let snapshotID = await snapshot.id
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "B9",
            "snapshot": snapshotID,
            "wait_for": 5000,
        ]))
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(response.isError == true)
        #expect(await MainActor.run { automation.targetedClickCalls.isEmpty })
    }

    @Test
    func `zero wait reports the current snapshot once`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        await snapshot.setUIElements([
            UIElement(
                id: "B1",
                elementId: "B1",
                role: "button",
                title: "Stay",
                label: "Stay",
                value: nil,
                description: nil,
                help: nil,
                roleDescription: "button",
                identifier: nil,
                frame: CGRect(x: 0, y: 0, width: 40, height: 20),
                isActionable: true),
        ])
        let snapshotID = await snapshot.id
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "query": "LateControl",
            "snapshot": snapshotID,
            "wait_for": 0,
        ]))
        #expect(response.isError == true)
        let text = response.content.compactMap { item -> String? in
            guard case let .text(text, _, _) = item else { return nil }
            return text
        }.joined()
        #expect(text.contains("LateControl"))
        #expect(await MainActor.run { automation.targetedClickCalls.isEmpty })
    }

    @Test
    func `negative wait is rejected`() async throws {
        let context = await MCPToolTestHelpers.makeLegacyContext(
            automation: MockAutomationService(accessibilityGranted: true))
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "query": "LateControl",
            "wait_for": -1,
        ]))
        #expect(response.isError == true)
    }

    @Test
    func `query wait requires an exact window`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let started = Date()
        let snapshotID = await snapshot.id
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "query": "LateControl",
            "snapshot": snapshotID,
            "wait_for": 5000,
        ]))
        #expect(Date().timeIntervalSince(started) < 1)
        let text = response.content.compactMap { item -> String? in
            guard case let .text(text, _, _) = item else { return nil }
            return text
        }.joined()
        #expect(text.contains("exact window"))
        #expect(await MainActor.run { automation.targetedClickCalls.isEmpty })
    }

    @Test
    func `ocr semantic evidence is refused without waiting`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        await snapshot.setUIElements([
            UIElement(
                id: "ocr_late",
                elementId: "ocr_late",
                role: "AXStaticText",
                title: "LateControl",
                label: "LateControl",
                description: "ocr",
                frame: CGRect(x: 0, y: 0, width: 40, height: 20),
                isActionable: false),
        ])
        let started = Date()
        let snapshotID = await snapshot.id
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "query": "LateControl",
            "snapshot": snapshotID,
            "wait_for": 5000,
        ]))
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(response.isError == true)
        #expect(Self.responseText(response).contains("semantic evidence"))
        #expect(await MainActor.run { automation.targetedClickCalls.isEmpty })
    }

    @Test
    func `reassigned window is refused before observation`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let windows = EmptyRecordingWindowService()
        let observation = CountingObservationService()
        let context = await MCPToolTestHelpers.makeLegacyContext(
            automation: automation,
            windows: windows,
            desktopObservation: observation)
        let snapshot = await context.uiSnapshots.createSnapshot()
        await Self.pinExactWindow(on: snapshot)
        let started = Date()
        let snapshotID = await snapshot.id
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "query": "LateControl",
            "snapshot": snapshotID,
            "wait_for": 5000,
        ]))
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(response.isError == true)
        #expect(Self.responseText(response).contains("changed while waiting"))
        let observed = await observation.callCount
        #expect(observed == 0)
        let listed = await windows.requestedWindowIDs
        #expect(listed == [6781])
    }

    @Test
    func `nested observation keeps the capture owner refusal`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let observation = CountingObservationService()
        let refusal = MCPToolCapturePreflightRefusal(
            message: "ScreenCaptureKit owner is unavailable.",
            hint: "Stop the other capture.")
        let context = await MCPToolTestHelpers.makeLegacyContext(
            automation: automation,
            desktopObservation: observation,
            capturePreflightRefusal: refusal)
        let snapshot = await context.uiSnapshots.createSnapshot()
        await Self.pinExactWindow(on: snapshot)
        let started = Date()
        let snapshotID = await snapshot.id
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "query": "LateControl",
            "snapshot": snapshotID,
            "wait_for": 5000,
        ]))
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(response.isError == true)
        #expect(Self.responseText(response).contains("ScreenCaptureKit owner is unavailable."))
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["error_code"] == .string("CAPTURE_FAILED"))
        let observed = await observation.callCount
        #expect(observed == 0)
    }

    @Test
    func `discarded observation screenshots are removed`() throws {
        let directory = FileManager.default.temporaryDirectory
        let raw = directory.appendingPathComponent("peekaboo-click-wait-\(UUID().uuidString).png")
        let annotated = URL(fileURLWithPath: ObservationOutputWriter.annotatedScreenshotPath(
            forRawScreenshotPath: raw.path))
        try Data([0x89]).write(to: raw)
        try Data([0x89]).write(to: annotated)
        ClickObservationFileCleanup.remove(screenshotPath: raw.path)
        #expect(FileManager.default.fileExists(atPath: raw.path) == false)
        #expect(FileManager.default.fileExists(atPath: annotated.path) == false)
    }

    private static func responseText(_ response: ToolResponse) -> String {
        response.content.compactMap { item -> String? in
            guard case let .text(text, _, _) = item else { return nil }
            return text
        }.joined()
    }

    private static func pinExactWindow(on snapshot: UISnapshot) async {
        let bounds = CGRect(x: 10, y: 20, width: 100, height: 40)
        let identity = WindowMutationIdentity(
            windowID: 6781,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 1001,
            capturedBounds: bounds)
        await snapshot.setTargetMetadata(from: WindowContext(
            windowID: 6781,
            windowBounds: bounds,
            windowMutationIdentity: identity,
            traversalBudget: nil))
    }
}

@MainActor
private final class CountingObservationService: DesktopObservationServiceProtocol {
    private(set) var callCount = 0

    func observe(_: DesktopObservationRequest) async throws -> DesktopObservationResult {
        self.callCount += 1
        throw CancellationError()
    }
}
