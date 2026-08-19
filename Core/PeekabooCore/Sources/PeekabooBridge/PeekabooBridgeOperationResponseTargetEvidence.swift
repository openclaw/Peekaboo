import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

extension PeekabooBridgeRequest {
    var browserConnectRequest: PeekabooBridgeBrowserChannelRequest? {
        switch self.unwrappedOperationRequest {
        case let .browserConnect(request):
            request
        default:
            nil
        }
    }

    var browserExecutionRequest: PeekabooBridgeBrowserExecuteRequest? {
        switch self.unwrappedOperationRequest {
        case let .browserExecute(request):
            request
        default:
            nil
        }
    }

    var browserRequestedChannel: String? {
        switch self.unwrappedOperationRequest {
        case let .browserConnect(request), let .browserStatus(request):
            request.channel
        case let .browserExecute(request):
            request.channel
        default:
            nil
        }
    }
}

extension PeekabooBridgeResponse {
    var browserExecutionResponse: PeekabooBridgeBrowserToolResponse? {
        switch self {
        case let .attestedOperation(payload):
            payload.response.browserExecutionResponse
        case let .projectedAction(payload):
            payload.response.browserExecutionResponse
        case let .browserToolResponse(response):
            response
        default:
            nil
        }
    }

    var browserExecutionConnectionReceipt: PeekabooBridgeBrowserConnectionReceipt? {
        switch self {
        case let .attestedOperation(payload):
            payload.response.browserExecutionConnectionReceipt
        case let .projectedAction(payload):
            payload.response.browserExecutionConnectionReceipt
        case let .browserStatus(status):
            status.connectionReceipt
        case let .browserToolResponse(response):
            response.connectionReceipt
        default:
            nil
        }
    }

    func operationTargetEvidence(
        for operation: PeekabooBridgeOperation) -> [DesktopTargetIdentity.Evidence]
    {
        switch self {
        case let .attestedOperation(payload):
            return payload.response.operationTargetEvidence(for: operation)
        case let .projectedAction(payload):
            return payload.response.operationTargetEvidence(for: operation)
        case let .desktopObservation(result):
            if let mutationTargetIdentity = result.target.mutationTargetIdentity {
                return [DesktopTargetEvidenceAdapter.evidence(
                    processIdentity: mutationTargetIdentity.processIdentity,
                    windowIdentity: mutationTargetIdentity.windowIdentity,
                    windowBounds: mutationTargetIdentity.windowBounds)]
            }
            return [
                result.target.detectionContext.map { DesktopTargetEvidenceAdapter.evidence(context: $0) },
                result.target.app.map { DesktopTargetEvidenceAdapter.evidence(application: $0) },
                result.target.window.map { DesktopTargetEvidenceAdapter.evidence(window: $0) },
            ].compactMap(\.self) + DesktopTargetEvidenceAdapter.fragments(captureMetadata: result.capture.metadata)
        case let .capture(result):
            return DesktopTargetEvidenceAdapter.fragments(captureMetadata: result.metadata)
        case let .elementDetection(result):
            return operation == .inspectAccessibilityTree
                ? result.metadata.windowContext.map { [DesktopTargetEvidenceAdapter.evidence(context: $0)] } ?? []
                : []
        case let .window(window):
            return PeekabooBridgeOperationResultSemantics.operationPolicy(for: operation)
                .windowResponseProof == .postMutationState
                ? []
                : window.map { [DesktopTargetEvidenceAdapter.evidence(window: $0)] } ?? []
        case let .application(application):
            return [DesktopTargetEvidenceAdapter.evidence(application: application)]
        case let .agentExecutionTrace(result):
            guard operation == .agentExecutionTrace else { return [] }
            let process = result.process.processIdentity
            return [.init(
                processIdentifier: process.processIdentifier,
                processIdentity: .init(
                    processIdentifier: process.processIdentifier,
                    processStartIdentity: process.processStartIdentity))]
        case let .browserToolResponse(result):
            return operation == .browserExecute
                ? [Self.browserEvidence(result.connectionReceipt)].compactMap(\.self)
                : []
        case let .browserStatus(status):
            return operation == .browserConnect
                ? [Self.browserEvidence(status.connectionReceipt)].compactMap(\.self)
                : []
        case let .preparedDialogAction(receipt):
            return [.init(target: DesktopTargetIdentity(exactWindow: receipt.target))]
        case let .dialogElements(elements):
            guard operation == .targetedDialogListElements,
                  let target = elements.resolvedTarget?.target
            else {
                return []
            }
            return [.init(target: DesktopTargetIdentity(exactWindow: target))]
        case let .dialogResult(result):
            return DesktopTargetEvidenceAdapter.fragments(dialogResult: result)
        case let .exactWindowHeldPointerTermination(termination?):
            return [DesktopTargetEvidenceAdapter.evidence(
                windowIdentity: termination.receipt.windowIdentity,
                bounds: termination.receipt.windowBounds)]
        case .focusedElement:
            return []
        case let .error(envelope):
            return envelope.actionTargetReceipt.map { [DesktopTargetEvidenceAdapter.evidence(receipt: $0)] } ?? []
        default:
            return []
        }
    }

    private static func browserEvidence(
        _ receipt: PeekabooBridgeBrowserConnectionReceipt?) -> DesktopTargetIdentity.Evidence?
    {
        guard let processIdentity = receipt?.localProcessIdentity else { return nil }
        return .init(
            processIdentifier: processIdentity.processIdentifier,
            processIdentity: processIdentity)
    }
}
