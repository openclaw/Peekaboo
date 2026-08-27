import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

extension PeekabooBridgeClient {
    public func createBrowserCapabilityNamespace() async throws
        -> PeekabooBridgeBrowserCapabilityNamespaceReceipt
    {
        try self.requireBrowserCapabilityNamespace(nativeWindowBinding: false)
        let response = try await self.send(.browserCreateCapabilityNamespace(.init()))
        switch response {
        case let .browserCapabilityNamespaceCreated(receipt):
            return receipt
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected browser capability namespace creation response")
        }
    }

    public func executeBrowserCapabilityNamespace(
        _ request: PeekabooBridgeBrowserCapabilityNamespaceRequest) async throws
        -> PeekabooBridgeBrowserCapabilityNamespaceActionResponse
    {
        try await self.executeBrowserCapabilityNamespaceResult(request).payload
    }

    public func executeBrowserCapabilityNamespaceResult(
        _ request: PeekabooBridgeBrowserCapabilityNamespaceRequest) async throws
        -> DesktopActionResult<PeekabooBridgeBrowserCapabilityNamespaceActionResponse>
    {
        let needsNativeWindowBinding = if case .bindWindow = request.action {
            true
        } else {
            false
        }
        try self.requireBrowserCapabilityNamespace(nativeWindowBinding: needsNativeWindowBinding)
        if request.executionMode == .backgroundOnly, request.requestsForegroundDelivery {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .foregroundRequired,
                message: "This browser namespace action requires explicit foreground authority.",
                hint: "Retry only with foreground_allowed when interrupting the user is intentional.")
        }
        let bridgeRequest = PeekabooBridgeRequest.browserCapabilityNamespace(request)
        if request.isReadOnly {
            let response = try await self.send(bridgeRequest)
            switch response {
            case let .browserCapabilityNamespaceAction(payload):
                try Self.validateBrowserCapabilityNamespaceResponse(payload, request: request)
                return .init(payload: payload, outcome: nil)
            case let .error(envelope):
                throw envelope
            default:
                throw PeekabooBridgeErrorEnvelope(
                    code: .invalidRequest,
                    message: "Unexpected browser capability namespace action response")
            }
        }
        let result = try await self.actionResult(
            for: bridgeRequest,
            expectedResponse: "browser capability namespace action",
            operationReceiptRequirement: .required)
        { response in
            guard case let .browserCapabilityNamespaceAction(payload) = response else { return nil }
            return payload
        }
        try Self.validateBrowserCapabilityNamespaceResponse(result.payload, request: request)
        return result.desktopActionResult
    }

    public func closeBrowserCapabilityNamespace(
        _ receipt: PeekabooBridgeBrowserCapabilityNamespaceReceipt) async throws
        -> PeekabooBridgeBrowserCapabilityNamespaceCloseResponse
    {
        try self.requireBrowserCapabilityNamespace(nativeWindowBinding: false)
        let response = try await self.send(.browserCloseCapabilityNamespace(.init(namespaceReceipt: receipt)))
        switch response {
        case let .browserCapabilityNamespaceClosed(closed)
            where closed.namespaceID == receipt.payload.namespaceID && closed.status == .closed:
            return closed
        case .browserCapabilityNamespaceClosed:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Browser capability namespace close response contradicted its receipt")
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected browser capability namespace close response")
        }
    }

    private func requireBrowserCapabilityNamespace(nativeWindowBinding: Bool) throws {
        guard self.browserCapabilityNamespacesEnabled else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "This Bridge host did not negotiate caller-owned browser capability namespaces.",
                hint: "Use a current local on-demand Peekaboo host and complete a fresh handshake.")
        }
        guard !nativeWindowBinding || self.nativeBrowserWindowBindingEnabled else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "This browser capability namespace cannot bind an exact native window.",
                hint: "Update the local on-demand Peekaboo host and create a new namespace.")
        }
    }

    private static func validateBrowserCapabilityNamespaceResponse(
        _ response: PeekabooBridgeBrowserCapabilityNamespaceActionResponse,
        request: PeekabooBridgeBrowserCapabilityNamespaceRequest) throws
    {
        if let receipt = response.nativeWindowReceipt {
            guard receipt.targetEvidence != nil,
                  case let .string(requestedPage)? = request.toolArguments["page_id"],
                  receipt.pageReference == requestedPage
            else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .invalidRequest,
                    message: "Browser namespace response carried contradictory native-window target evidence")
            }
        }
        guard case let .bindWindow(binding) = request.action else {
            // Verified operation receipts independently require this typed evidence whenever the signed mutation
            // target is an exact window, so a bound mutation cannot be accepted merely because this client is
            // stateless.
            return
        }
        guard let receipt = response.nativeWindowReceipt,
              receipt.processIdentifier == binding.processIdentifier,
              receipt.windowID == binding.windowID
        else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Browser native-window binding response omitted or contradicted its exact target receipt")
        }
    }
}
