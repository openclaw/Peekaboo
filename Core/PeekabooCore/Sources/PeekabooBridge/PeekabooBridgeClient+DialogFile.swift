import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

extension PeekabooBridgeClient {
    public func dialogHandleFile(_ request: DialogFileExecutionRequest) async throws -> DialogActionResult {
        try self.requireExactFileDialogExecution()
        let reply = try await self.sendCarryingActionOutcome(
            .dialogHandleFile(.init(execution: request)),
            operationReceiptRequirement: .required)
        switch reply.response {
        case let .dialogResult(result):
            guard result.success,
                  result.action == .handleFileDialog,
                  let outcome = result.outcome,
                  let targetReceipt = result.targetReceipt,
                  result.targetWindowIdentity != nil,
                  result.targetWindowBounds != nil,
                  request.target.processIdentifier.map({ $0 == targetReceipt.processIdentifier }) ?? true,
                  request.target.windowID.map({ $0 == targetReceipt.windowID }) ?? true,
                  reply.outcome?.outcome == outcome.routed(to: .bridge)
            else {
                throw DesktopActionFailure.indeterminate(
                    route: .bridge,
                    evidence: .completionUnknown,
                    unitCount: reply.outcome?.outcome.dispatchState.unitCount,
                    message: "Bridge file execution did not return its exact target and canonical outcome.",
                    hint: "Observe the file dialog before retrying and update the selected host.")
            }
            return DialogActionResult(
                success: result.success,
                action: result.action,
                details: result.details,
                outcome: outcome.routed(to: .bridge),
                targetReceipt: targetReceipt,
                targetWindowIdentity: result.targetWindowIdentity,
                targetWindowBounds: result.targetWindowBounds,
                focusedElement: result.focusedElement,
                resolvedTarget: result.resolvedTarget)
        case let .error(envelope):
            if let failure = envelope.desktopActionFailure {
                throw failure.routed(to: .bridge)
            }
            throw envelope
        default:
            throw DesktopActionFailure.indeterminate(
                route: .bridge,
                evidence: .completionUnknown,
                unitCount: reply.outcome?.outcome.dispatchState.unitCount,
                message: "Bridge returned an unexpected exact file-dialog response.",
                hint: "Observe the file dialog before retrying and update the selected host.")
        }
    }

    func requireExactFileDialogExecution() throws {
        guard self.exactFileDialogExecutionEnabled, !self.usesExplicitReceiptlessTransport() else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "Bridge host does not advertise exact file-dialog execution; no input was sent.",
                hint: "Select a current signed host advertising exactFileDialogExecution.")
        }
    }
}
