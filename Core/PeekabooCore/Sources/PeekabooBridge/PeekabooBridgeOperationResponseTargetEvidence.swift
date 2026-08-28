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
        for plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan)
        -> [DesktopTargetIdentity.Evidence]
    {
        switch self {
        case let .attestedOperation(payload):
            return payload.response.operationTargetEvidence(for: plan)
        case let .projectedAction(payload):
            return payload.response.operationTargetEvidence(for: plan)
        case let .desktopObservation(result) where plan.target.responseEvidenceSource == .desktopObservation:
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
        case let .capture(result) where plan.target.responseEvidenceSource == .capture:
            return DesktopTargetEvidenceAdapter.fragments(captureMetadata: result.metadata)
        case let .elementDetection(result) where plan.target.responseEvidenceSource == .inspectWindowContext:
            return result.metadata.windowContext.map { [DesktopTargetEvidenceAdapter.evidence(context: $0)] } ?? []
        case let .window(window) where plan.target.responseEvidenceSource == .window:
            return plan.responseCarriesPostMutationWindowState
                ? []
                : window.map { [DesktopTargetEvidenceAdapter.evidence(window: $0)] } ?? []
        case let .application(application) where plan.target.responseEvidenceSource == .application:
            return [DesktopTargetEvidenceAdapter.evidence(application: application)]
        case let .agentExecutionTrace(result) where plan.target.responseEvidenceSource == .agentProcess:
            let process = result.process.processIdentity
            return [.init(
                processIdentifier: process.processIdentifier,
                processIdentity: .init(
                    processIdentifier: process.processIdentifier,
                    processStartIdentity: process.processStartIdentity))]
        case let .browserToolResponse(result)
            where plan.operation == .browserExecute && plan.target.responseEvidenceSource == .browserConnection:
            return [Self.browserEvidence(result.connectionReceipt)].compactMap(\.self)
        case let .browserStatus(status)
            where plan.operation == .browserConnect && plan.target.responseEvidenceSource == .browserConnection:
            return [Self.browserEvidence(status.connectionReceipt)].compactMap(\.self)
        case let .preparedDialogAction(receipt) where plan.target.responseEvidenceSource == .preparedDialog:
            return [.init(target: DesktopTargetIdentity(exactWindow: receipt.target))]
        case let .dialogElements(elements) where plan.target.responseEvidenceSource == .targetedDialog:
            guard let target = elements.resolvedTarget?.target
            else {
                return []
            }
            return [.init(target: DesktopTargetIdentity(exactWindow: target))]
        case let .dialogResult(result) where plan.target.responseEvidenceSource == .dialog:
            return DesktopTargetEvidenceAdapter.fragments(dialogResult: result)
        case let .exactWindowHeldPointerTermination(termination?)
            where plan.target.responseEvidenceSource == .heldPointerTermination:
            return [DesktopTargetEvidenceAdapter.evidence(
                windowIdentity: termination.receipt.windowIdentity,
                bounds: termination.receipt.windowBounds)]
        case let .error(envelope):
            return envelope.actionTargetReceipt.map { [DesktopTargetEvidenceAdapter.evidence(receipt: $0)] } ?? []
        case .operationSessionRollover,
             .handshake,
             .permissionsStatus,
             .daemonStatus,
             .agentExecutionTrace,
             .processGenerationObservation,
             .certificationProducerAttestation,
             .browserStatus,
             .browserToolResponse,
             .browserSessionBootstrap,
             .capture,
             .elementDetection,
             .focusedElement,
             .desktopObservation,
             .ok,
             .waitResult,
             .windows,
             .windowMutationInventory,
             .window,
             .applications,
             .applicationMutationInventory,
             .application,
             .bool,
             .typeResult,
             .foregroundModifierClickResult,
             .exactWindowHeldPointerOwner,
             .exactWindowHeldPointerReceipt,
             .exactWindowHeldPointerTermination,
             .elementActionResult,
             .clickResult,
             .menuStructure,
             .menuExtras,
             .menuBarItems,
             .dockItems,
             .dockItem,
             .rect,
             .dialogInfo,
             .dialogElements,
             .dialogResult,
             .preparedDialogAction,
             .snapshotId,
             .snapshotMutationLease,
             .snapshots,
             .detection,
             .int:
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
