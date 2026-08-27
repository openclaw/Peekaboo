import Foundation

enum PeekabooBridgeBrowserCapabilityNamespaceReceiptValidation {
    static func validateNativeTarget(
        _ payload: PeekabooBridgeOperationReceiptPayload,
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse,
        plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan) throws
    {
        guard request.operation == .browserCapabilityNamespace,
              plan.result.completion.mutatesDesktop,
              !PeekabooBridgeOperationResultSemantics.isNoDispatchFailure(response)
        else { return }
        let responseReceipt = response.browserCapabilityNamespaceResponse?.nativeWindowReceipt
        guard case let .window(signedWindow) = payload.target else {
            guard responseReceipt == nil else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "unbound browser namespace native-window target")
            }
            return
        }
        guard let responseReceipt,
              let responseWindow = responseReceipt.targetEvidence?.windowIdentity,
              signedWindow.hasSameStableReceipt(as: responseWindow),
              case let .browserCapabilityNamespace(namespaceRequest) = request.unwrappedOperationRequest,
              case let .string(requestedPage)? = namespaceRequest.toolArguments["page_id"],
              requestedPage == responseReceipt.pageReference
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                "bound browser namespace native-window target")
        }
    }
}
