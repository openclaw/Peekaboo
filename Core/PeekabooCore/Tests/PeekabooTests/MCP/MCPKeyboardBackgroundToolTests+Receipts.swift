import CoreGraphics
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

private let keyboardReceiptSnapshots = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner())

extension MCPKeyboardBackgroundToolTests {
    @Test
    func `Press and Type refuse malformed exact-window snapshot receipts before dispatch`() async throws {
        await keyboardReceiptSnapshots.removeAllSnapshots()
        let processIdentifier: pid_t = 447
        let processStartIdentity: UInt64 = 47
        let bounds = CGRect(x: 10, y: 20, width: 640, height: 480)
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run {
            MockApplicationService(applications: [AutomationTestFixtures.application(
                processIdentifier: processIdentifier,
                processStartIdentity: processStartIdentity,
                bundleIdentifier: "com.example.receipt",
                name: "ReceiptApp")])
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            snapshotOwner: keyboardReceiptSnapshots.owner)
        let invalidReceipts: [(name: String, windowID: Int, capturedBounds: CGRect?)] = [
            ("missing captured bounds", 42, nil),
            ("mismatched captured bounds", 42, bounds.offsetBy(dx: 1, dy: 0)),
            ("zero window ID", 0, bounds),
            ("out-of-range window ID", Int(UInt32.max) + 1, bounds),
        ]

        for invalid in invalidReceipts {
            let snapshotID = await self.makeExactWindowSnapshot(
                processIdentifier: processIdentifier,
                processStartIdentity: processStartIdentity,
                windowID: invalid.windowID,
                windowBounds: bounds,
                capturedBounds: invalid.capturedBounds)

            let pressResponse = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
                "snapshot": snapshotID,
                "keys": ["cmd+l"],
            ]))
            let typeResponse = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
                "snapshot": snapshotID,
                "text": "hello",
            ]))

            #expect(pressResponse.isError, "Press accepted \(invalid.name)")
            #expect(typeResponse.isError, "Type accepted \(invalid.name)")
        }

        #expect(await MainActor.run { automation.lastHotkeyKeys } == nil)
        #expect(await MainActor.run { automation.lastTypeActions } == nil)
        #expect(await MainActor.run { automation.targetedHotkeyCalls.isEmpty })
        #expect(await MainActor.run { automation.targetedTypeActionsCalls.isEmpty })
    }

    private func makeExactWindowSnapshot(
        processIdentifier: pid_t,
        processStartIdentity: UInt64,
        windowID: Int,
        windowBounds: CGRect,
        capturedBounds: CGRect?) async -> String
    {
        let snapshot = await keyboardReceiptSnapshots.createSnapshot()
        let snapshotID = await snapshot.id
        let application = AutomationTestFixtures.application(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity,
            bundleIdentifier: "com.example.receipt",
            name: "ReceiptApp")
        let window = ServiceWindowInfo(
            windowID: windowID,
            title: "Receipt Window",
            bounds: windowBounds,
            mutationIdentity: WindowMutationIdentity(
                windowID: windowID,
                ownerProcessIdentifier: processIdentifier,
                ownerProcessStartIdentity: processStartIdentity,
                capturedBounds: capturedBounds))
        await snapshot.setScreenshot(
            path: "/tmp/receipt-\(snapshotID).png",
            metadata: CaptureMetadata(
                size: windowBounds.size,
                mode: .window,
                applicationInfo: application,
                windowInfo: window))
        return snapshotID
    }
}
