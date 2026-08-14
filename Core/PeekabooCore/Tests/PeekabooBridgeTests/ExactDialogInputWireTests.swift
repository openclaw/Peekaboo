import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

struct ExactDialogInputWireTests {
    @Test
    func `protocol 1 27 gates exact input while retaining legacy input`() {
        let operations: Set<PeekabooBridgeOperation> = [.dialogEnterText, .exactDialogEnterText]
        let legacyVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 26)

        #expect(PeekabooBridgeConstants.protocolVersion == .init(major: 1, minor: 27))
        #expect(PeekabooBridgeConstants.exactDialogInputExecutionVersion == .init(major: 1, minor: 27))
        #expect(PeekabooBridgeHostCapability.exactDialogInputExecution == "exactDialogInputExecution")
        #expect(PeekabooBridgeOperation.exactDialogEnterText.requiredPermissions == [.accessibility, .postEvent])
        #expect(PeekabooBridgeOperation.compatible(operations, with: legacyVersion) == [.dialogEnterText])
        #expect(PeekabooBridgeOperation.compatible(
            operations,
            with: PeekabooBridgeConstants.protocolVersion) == operations)
    }

    @Test
    func `exact input request round trip retains target text field clear and focus policy`() throws {
        let target = try DialogTargetSelector(
            processIdentifier: 4242,
            windowID: 700)
        let request = try DialogInputExecutionRequest(
            target: target,
            text: "bridge payload",
            fieldIdentifier: "Account name",
            clearExisting: true,
            focus: DialogInputFocusPolicy(
                autoFocus: false,
                timeout: 2.75,
                retryCount: 4,
                switchSpace: true,
                bringToCurrentSpace: true))
        let wireRequest = PeekabooBridgeRequest.exactDialogEnterText(request)

        let data = try JSONEncoder.peekabooBridgeEncoder().encode(wireRequest)
        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeRequest.self, from: data)

        #expect(decoded.operation == .exactDialogEnterText)
        guard case let .exactDialogEnterText(decodedRequest) = decoded else {
            Issue.record("Expected exact dialog input request")
            return
        }
        #expect(decodedRequest == request)
    }

    @Test
    func `dialog result round trip retains typed target receipt and canonical outcome`() throws {
        let bounds = CGRect(x: 10, y: 20, width: 480, height: 320)
        let identity = WindowMutationIdentity(
            windowID: 700,
            ownerProcessIdentifier: 4242,
            ownerProcessStartIdentity: 99,
            capturedBounds: bounds)
        let receipt = DesktopActionTargetReceipt(
            processIdentifier: identity.ownerProcessIdentifier,
            processStartIdentity: identity.ownerProcessStartIdentity,
            windowID: identity.windowID)
        let result = DialogActionResult(
            success: true,
            action: .enterText,
            details: ["focus_policy": "require_existing"],
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .deliveryAccepted),
            targetReceipt: receipt)

        let data = try JSONEncoder.peekabooBridgeEncoder().encode(PeekabooBridgeResponse.dialogResult(result))
        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: data)

        guard case let .dialogResult(decodedResult) = decoded else {
            Issue.record("Expected dialog result")
            return
        }
        #expect(decodedResult.targetReceipt == receipt)
        #expect(decodedResult.outcome == result.outcome)
        #expect(decodedResult.details == result.details)
    }
}
