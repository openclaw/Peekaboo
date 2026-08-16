import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

struct ObservationPolicyRequestTests {
    @Test
    func `MCP observations default web focus off`() throws {
        #expect(try !(SeeRequest(arguments: ToolArguments(raw: [:])).webFocus))
        #expect(try !InspectUIRequest(arguments: ToolArguments(raw: [:])).webFocus)
    }

    @Test
    func `MCP observations accept explicit web focus`() throws {
        let arguments = ToolArguments(raw: ["web_focus": true])
        #expect(try SeeRequest(arguments: arguments).webFocus)
        #expect(try InspectUIRequest(arguments: arguments).webFocus)
    }

    @Test
    func `MCP image defaults to background capture`() throws {
        #expect(try ImageRequest(arguments: ToolArguments(raw: [:])).captureFocus == .background)
        #expect(try ImageRequest(arguments: ToolArguments(raw: ["capture_focus": "foreground"])).captureFocus ==
            .foreground)
    }

    @Test
    func `Shared observation models default to background and read only`() {
        #expect(DesktopCaptureOptions().focus == .background)
        #expect(!DesktopDetectionOptions().allowWebFocusFallback)
    }

    @Test
    @MainActor
    func `legacy element detection reports conservative web focus outcome`() async throws {
        let expected = ElementDetectionResult(
            snapshotId: "detection",
            screenshotPath: "",
            elements: DetectedElements(),
            metadata: DetectionMetadata(detectionTime: 0, elementCount: 0, method: "stub"))
        let automation = InspectUITestAutomationService(
            accessibilityGranted: true,
            detectionResult: expected)

        let result = try await automation.detectElementsResult(
            in: Data(),
            snapshotId: nil,
            windowContext: WindowContext(shouldFocusWebContent: true))

        #expect(result.payload.snapshotId == expected.snapshotId)
        #expect(result.outcome?.state == .dispatchedUnverified)
        #expect(result.outcome?.delivery == .init(mechanism: .accessibilityAction, mode: .background))
        #expect(result.outcome?.dispatchState.unitCount == .one)
    }

    @Test
    @MainActor
    func `legacy accessibility inspection failure is unsafe when web focus may dispatch`() async throws {
        let automation = InspectUITestAutomationService(
            accessibilityGranted: true,
            inspectError: POSIXError(.ETIMEDOUT))

        do {
            _ = try await automation.inspectAccessibilityTreeResult(
                windowContext: WindowContext(shouldFocusWebContent: true))
            Issue.record("Expected indeterminate observation failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.mutationDispatched)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.evidence == .completionUnknown)
        }
    }
}
