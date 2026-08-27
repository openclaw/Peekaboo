import CoreGraphics
import MCP
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

extension BrowserTool {
    @MainActor
    func executeNativeWindowBindingResponse(arguments: ToolArguments) async throws -> ToolResponse {
        do {
            return try await self.executeNativeWindowBinding(arguments: arguments)
        } catch is CancellationError {
            return try MCPToolResponseMetadataProjector.errorResponse(
                for: .preDispatchRefusal(
                    reason: .requestCancelled,
                    message: "Native browser window binding was cancelled before any browser mutation.",
                    hint: "Retry only if the same page-to-window binding is still wanted."),
                invalidatedSnapshotID: nil)
        } catch let failure as DesktopActionFailure {
            return try MCPToolResponseMetadataProjector.errorResponse(
                for: failure,
                invalidatedSnapshotID: nil)
        } catch let error as BrowserToolNativeWindowBindingError {
            return try MCPToolResponseMetadataProjector.errorResponse(
                for: Self.nativeWindowBindingFailure(error),
                invalidatedSnapshotID: nil)
        } catch let error as BrowserNativeWindowBindingCoordinatorError {
            return try MCPToolResponseMetadataProjector.errorResponse(
                for: Self.nativeWindowBindingFailure(error),
                invalidatedSnapshotID: nil)
        } catch {
            return try MCPToolResponseMetadataProjector.errorResponse(
                for: .preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Native browser window binding could not establish exact authority.",
                    hint: "Refresh browser pages and native windows before retrying.",
                    causeDescription: error.localizedDescription),
                invalidatedSnapshotID: nil)
        }
    }

    @MainActor
    private func executeNativeWindowBinding(arguments: ToolArguments) async throws -> ToolResponse {
        guard let capabilitySession = self.capabilitySession,
              let provider = self.nativeWindowBindingProvider
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .operationUnsupported,
                message: "Native browser window binding requires one process-local scoped MCP or Agent session.",
                hint: "Use the browser tool through a local MCP or Agent session; standalone CLI and remote Bridge " +
                    "binding remain unavailable until an authenticated 1.38 browser namespace exists.")
        }
        let allowedKeys: Set = ["action", "page_id", "pid", "window_id"]
        let unexpectedKeys = Set(arguments.rawDictionary.keys).subtracting(allowedKeys).sorted()
        guard unexpectedKeys.isEmpty else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "bind_window received unsupported argument(s): \(unexpectedKeys.joined(separator: ", ")).",
                hint: "Pass exactly action, page_id, pid, and window_id.")
        }
        guard let pageReference = arguments.getString("page_id"),
              BrowserToolCapabilityReference.isValid(pageReference, prefix: "bp1")
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "bind_window requires an opaque page_id from this session.",
                hint: "Run list_pages in the same session and use its bp1 reference.")
        }
        guard let rawPID = try arguments.validatedInt("pid"),
              let processIdentifier = Int32(exactly: rawPID),
              processIdentifier > 0
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "bind_window pid must be a positive Int32.",
                hint: "Use the exact PID reported by browser status and native window inventory.")
        }
        guard let rawWindowID = try arguments.validatedInt("window_id"),
              let windowID = UInt32(exactly: rawWindowID),
              windowID > 0
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "bind_window window_id must be a positive UInt32.",
                hint: "Use the exact WindowServer ID from native window inventory.")
        }

        return try await capabilitySession.withExclusiveOperation {
            let status = await self.client.status(channel: nil)
            await capabilitySession.observeStatus(status)
            guard self.client.supportsNativeBrowserConnectionBinding,
                  status.isConnected,
                  let receipt = status.connectionReceipt,
                  let generation = receipt.processStartIdentity,
                  receipt.processIdentifier == processIdentifier,
                  let channel = receipt.channel,
                  let channelIdentity = ChromeChannelIdentity(rawValue: channel.rawValue),
                  receipt.bundleIdentifier == channelIdentity.bundleIdentifier,
                  let browserURL = receipt.browserURL,
                  let webSocketDebuggerURL = receipt.webSocketDebuggerURL,
                  let browserID = receipt.devToolsBrowserID,
                  BrowserLoopbackEndpoint(browserURL: browserURL)?.matchesWebSocketDebuggerURL(
                      webSocketDebuggerURL,
                      browserID: browserID) == true
            else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "bind_window requires the current process-bound official Chrome connection receipt.",
                    hint: "Connect one local Chrome channel explicitly, refresh status, and retry with its exact PID.")
            }
            let proof = try await provider.bindNativeWindowHoldingCapabilityGate(
                pageReference: pageReference,
                target: BrowserNativeWindowTarget(
                    processIdentifier: processIdentifier,
                    processStartIdentity: generation,
                    windowID: CGWindowID(windowID)),
                expectedSessionBinding: .init(
                    connectionReceipt: receipt,
                    providerSessionEpoch: Self.requireProviderSessionEpoch(status)),
                deadline: ContinuousClock.now.advanced(by: .seconds(10)))
            return try Self.nativeWindowBindingResponse(proof)
        }
    }

    private static func requireProviderSessionEpoch(
        _ status: BrowserMCPStatus) throws -> BrowserMCPProviderSessionEpoch
    {
        guard let epoch = status.providerSessionEpoch else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The browser provider child has no exact session epoch.",
                hint: "Reconnect the process-local browser session and retry.")
        }
        return epoch
    }

    private static func nativeWindowBindingResponse(
        _ proof: BrowserNativeWindowBindingProof) throws -> ToolResponse
    {
        let receipt = proof.nativeWindowReceipt
        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: receipt.windowIdentity,
            bounds: receipt.bounds)
        let identity = DesktopTargetIdentity(exactWindow: exactWindow)
        let bindingFields: [String: Value] = [
            "state": .string("bound"),
            "page_id": .string(proof.pageReference),
            "pid": .int(Int(receipt.target.processIdentifier)),
            "process_start_identity_decimal": .string(String(receipt.target.processStartIdentity)),
            "window_id": .int(Int(receipt.target.windowID)),
            "bounds": .object([
                "x": .double(Double(receipt.bounds.origin.x)),
                "y": .double(Double(receipt.bounds.origin.y)),
                "width": .double(Double(receipt.bounds.width)),
                "height": .double(Double(receipt.bounds.height)),
            ]),
            "quality": .string(proof.quality.rawValue),
        ]
        let meta = try MCPDesktopTargetMetadataProjector.fields(
            identity,
            merging: ["browser_window_binding": .object(bindingFields)])
        return ToolResponse.text(
            "Bound page \(proof.pageReference) to Chrome pid \(receipt.target.processIdentifier) " +
                "window \(receipt.target.windowID) (exact).",
            meta: .object(meta))
    }

    static func nativeWindowBindingFailure(_ error: any Error) -> DesktopActionFailure {
        let reason: DesktopActionOutcome.RefusalReason
        let message: String
        let hint: String
        switch error {
        case BrowserNativeWindowBindingCoordinatorError.controlUnavailable:
            reason = .transportSessionUnavailable
            message = "The retained native browser control session is unavailable."
            hint = "Reconnect the process-local browser session and bind the page again."
        case BrowserNativeWindowBindingCoordinatorError.deadlineExceeded:
            reason = .targetUnavailable
            message = "Native browser window validation exceeded its deadline before mutation dispatch."
            hint = "Refresh browser and native window state before retrying."
        default:
            reason = .targetUnavailable
            message = "The opaque browser page no longer has valid exact native-window authority."
            hint = "Refresh list_pages and native windows, then bind the page again."
        }
        return .preDispatchRefusal(
            reason: reason,
            message: message,
            hint: hint,
            causeDescription: error.localizedDescription)
    }
}
