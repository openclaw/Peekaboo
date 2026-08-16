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
                return [.init(
                    processIdentifier: mutationTargetIdentity.processIdentity.processIdentifier,
                    processIdentity: mutationTargetIdentity.processIdentity,
                    windowID: mutationTargetIdentity.windowIdentity?.windowID,
                    windowIdentity: mutationTargetIdentity.windowIdentity,
                    windowBounds: mutationTargetIdentity.windowBounds)]
            }
            return [
                Self.evidence(result.target.detectionContext),
                Self.evidence(result.target.app),
                Self.evidence(result.target.window),
            ].compactMap(\.self) + Self.evidence(result.capture.metadata)
        case let .capture(result):
            return Self.evidence(result.metadata)
        case let .elementDetection(result):
            return operation == .inspectAccessibilityTree
                ? [Self.evidence(result.metadata.windowContext)].compactMap(\.self)
                : []
        case let .window(window):
            return PeekabooBridgeOperationResultSemantics.operationPolicy(for: operation)
                .windowResponseProof == .postMutationState
                ? []
                : window.map(Self.evidence).map { [$0] } ?? []
        case let .application(application):
            return [Self.evidence(application)].compactMap(\.self)
        case let .browserToolResponse(result):
            return operation == .browserExecute
                ? [Self.evidence(result.connectionReceipt)].compactMap(\.self)
                : []
        case let .browserStatus(status):
            return operation == .browserConnect
                ? [Self.evidence(status.connectionReceipt)].compactMap(\.self)
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
            return Self.evidence(result)
        case .focusedElement:
            return []
        case let .error(envelope):
            return [Self.evidence(envelope.actionTargetReceipt)].compactMap(\.self)
        default:
            return []
        }
    }

    private static func evidence(_ metadata: CaptureMetadata) -> [DesktopTargetIdentity.Evidence] {
        [
            self.evidence(metadata.applicationInfo),
            metadata.windowInfo.map(self.evidence),
        ].compactMap(\.self)
    }

    private static func evidence(_ context: WindowContext?) -> DesktopTargetIdentity.Evidence? {
        guard let context else { return nil }
        return .init(
            processIdentifier: context.applicationProcessId,
            windowID: context.windowID,
            windowIdentity: context.windowMutationIdentity,
            windowBounds: context.windowBounds,
            focusedElement: context.focusedElement)
    }

    private static func evidence(_ window: WindowIdentity?) -> DesktopTargetIdentity.Evidence? {
        guard let window else { return nil }
        return .init(windowID: window.windowID, windowBounds: window.bounds)
    }

    private static func evidence(_ window: ServiceWindowInfo) -> DesktopTargetIdentity.Evidence {
        .init(
            processIdentifier: window.mutationIdentity?.ownerProcessIdentifier,
            processIdentity: window.mutationIdentity?.processIdentity,
            windowID: window.windowID,
            windowIdentity: window.mutationIdentity,
            windowBounds: window.bounds)
    }

    private static func evidence(_ identity: WindowMutationIdentity) -> DesktopTargetIdentity.Evidence {
        .init(
            processIdentifier: identity.ownerProcessIdentifier,
            processIdentity: identity.processIdentity,
            windowID: identity.windowID,
            windowIdentity: identity,
            windowBounds: identity.capturedBounds)
    }

    private static func evidence(_ application: ApplicationIdentity?) -> DesktopTargetIdentity.Evidence? {
        guard let application else { return nil }
        return .init(
            processIdentifier: application.processIdentifier,
            processIdentity: application.processStartIdentity.map {
                .init(
                    processIdentifier: application.processIdentifier,
                    processStartIdentity: $0)
            })
    }

    private static func evidence(
        _ receipt: PeekabooBridgeBrowserConnectionReceipt?) -> DesktopTargetIdentity.Evidence?
    {
        guard let processIdentity = receipt?.localProcessIdentity else { return nil }
        return .init(
            processIdentifier: processIdentity.processIdentifier,
            processIdentity: processIdentity)
    }

    private static func evidence(
        _ application: ServiceApplicationInfo?) -> DesktopTargetIdentity.Evidence?
    {
        guard let application else { return nil }
        return .init(
            processIdentifier: application.processIdentifier,
            processIdentity: application.processStartIdentity.map {
                .init(
                    processIdentifier: application.processIdentifier,
                    processStartIdentity: $0)
            })
    }

    private static func evidence(_ result: DialogActionResult) -> [DesktopTargetIdentity.Evidence] {
        var evidence: [DesktopTargetIdentity.Evidence] = []
        if let resolvedTarget = result.resolvedTarget {
            evidence.append(.init(target: DesktopTargetIdentity(exactWindow: resolvedTarget.target)))
        }
        if result.targetWindowIdentity != nil || result.targetWindowBounds != nil || result.focusedElement != nil {
            evidence.append(.init(
                processIdentifier: result.targetWindowIdentity?.ownerProcessIdentifier,
                processIdentity: result.targetWindowIdentity?.processIdentity,
                windowID: result.targetWindowIdentity?.windowID,
                windowIdentity: result.targetWindowIdentity,
                windowBounds: result.targetWindowBounds,
                focusedElement: result.focusedElement))
        }
        if let receiptEvidence = self.evidence(result.targetReceipt) {
            evidence.append(receiptEvidence)
        }
        return evidence
    }

    private static func evidence(
        _ receipt: DesktopActionTargetReceipt?) -> DesktopTargetIdentity.Evidence?
    {
        guard let receipt else { return nil }
        return .init(
            processIdentifier: receipt.processIdentifier,
            processIdentity: .init(
                processIdentifier: receipt.processIdentifier,
                processStartIdentity: receipt.processStartIdentity),
            windowID: receipt.windowID)
    }
}
