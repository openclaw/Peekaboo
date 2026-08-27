import Foundation
import MCP
import PeekabooAgentRuntime
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation
import TachikomaMCP

@MainActor
extension PeekabooServices: PeekabooBridgeBrowserConnectionResultProviding {
    public var supportsNativeBrowserConnectionBinding: Bool {
        self.browser.supportsNativeBrowserConnectionBinding
    }

    public func browserStatus(channel: String?) async throws -> PeekabooBridgeBrowserStatus {
        let status = try await self.browser.status(channel: Self.browserChannel(from: channel))
        return Self.bridgeStatus(from: status)
    }

    public func browserConnect(channel: String?) async throws -> PeekabooBridgeBrowserStatus {
        try await self.browserConnect(channel: channel, browserURL: nil)
    }

    public func browserConnect(channel: String?, browserURL: String?) async throws -> PeekabooBridgeBrowserStatus {
        do {
            let status = try await self.browser.connect(
                channel: Self.browserChannel(from: channel),
                browserURL: browserURL)
            return Self.bridgeStatus(from: status)
        } catch BrowserMCPConnectionError.targetLocked {
            throw Self.browserTargetLockedFailure()
        }
    }

    public func browserConnectResult(
        channel: String?,
        browserURL: String?) async throws -> DesktopActionResult<PeekabooBridgeBrowserStatus>
    {
        guard let resultBrowser = self.browser as? any BrowserMCPConnectionResultProviding else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .operationUnsupported,
                message: "The browser provider cannot report canonical connection outcomes.",
                hint: "Update the runtime host before retrying browser connect.")
        }
        do {
            let result = try await resultBrowser.connectWithOutcome(
                channel: Self.browserChannel(from: channel),
                browserURL: browserURL)
            return DesktopActionResult(
                payload: Self.bridgeStatus(from: result.payload),
                outcome: result.outcome)
        } catch BrowserMCPConnectionError.targetLocked {
            throw Self.browserTargetLockedFailure()
        }
    }

    public func browserDisconnect() async throws {
        await self.browser.disconnect()
    }

    public func browserExecute(_ request: PeekabooBridgeBrowserExecuteRequest) async throws
        -> PeekabooBridgeBrowserToolResponse
    {
        let calls = request.resolvedCalls.map { call in
            BrowserMCPMappedCall(
                toolName: call.toolName,
                arguments: call.arguments.mapValues { $0.toAny() })
        }
        if let expectedConnectionReceipt = request.expectedConnectionReceipt {
            do {
                let result = try await self.browser.executeSequence(
                    calls,
                    channel: Self.browserChannel(from: request.channel),
                    expectedConnectionReceipt: Self.browserReceipt(from: expectedConnectionReceipt))
                return try Self.bridgeToolResponse(from: result)
            } catch BrowserMCPConnectionError.expectedConnectionReceiptMismatch {
                return Self.bridgeBrowserRefusalResponse(.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "The exact browser connection changed before tool dispatch.",
                    hint: "Refresh browser status and retry against its new connection receipt."))
            } catch BrowserMCPConnectionError.receiptBindingUnsupported {
                return Self.bridgeBrowserRefusalResponse(.preDispatchRefusal(
                    reason: .operationUnsupported,
                    message: "The browser provider cannot atomically bind execution to a connection receipt.",
                    hint: "Update the runtime host before retrying target-attested browser execution."))
            } catch let failure as DesktopActionFailure {
                return Self.bridgeBrowserRefusalResponse(failure)
            }
        }
        if request.connectionPolicy == .requireExistingLiveReceipt {
            return Self.bridgeBrowserRefusalResponse(.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Existing-connection-only browser execution requires an exact connection receipt.",
                hint: "Refresh browser status and bind its complete receipt before retrying."))
        }
        let response = try await self.browser.executeSequence(
            calls,
            channel: Self.browserChannel(from: request.channel))
        return try Self.bridgeToolResponse(from: response)
    }

    public func browserExecute(
        _ request: PeekabooBridgeBrowserExecuteRequest,
        expectedConnectionReceipt: PeekabooBridgeBrowserConnectionReceipt) async throws
        -> PeekabooBridgeBrowserExecutionResult
    {
        let calls = request.resolvedCalls.map { call in
            BrowserMCPMappedCall(
                toolName: call.toolName,
                arguments: call.arguments.mapValues { $0.toAny() })
        }
        let expectedReceipt = try Self.browserReceipt(from: expectedConnectionReceipt)
        let result: BrowserMCPExecutionResult
        do {
            result = try await self.browser.executeSequence(
                calls,
                channel: Self.browserChannel(from: request.channel),
                expectedConnectionReceipt: expectedReceipt)
        } catch BrowserMCPConnectionError.expectedConnectionReceiptMismatch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The exact browser connection changed before tool dispatch.",
                hint: "Refresh browser status and retry against its new connection receipt.")
        } catch BrowserMCPConnectionError.receiptBindingUnsupported {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .operationUnsupported,
                message: "The browser provider cannot atomically bind execution to a connection receipt.",
                hint: "Update the runtime host before retrying target-attested browser execution.")
        }
        if request.isReadOnly {
            return try PeekabooBridgeBrowserExecutionResult(
                response: Self.bridgeToolResponse(from: result.response),
                connectionReceipt: Self.bridgeReceipt(from: result.connectionReceipt),
                completedCallCount: result.completedCallCount,
                dispatchedCallCount: result.dispatchedCallCount,
                actionFailure: result.actionFailure)
        }
        let projected = try result.projectingMutationProgress(for: calls)
        return try PeekabooBridgeBrowserExecutionResult(
            response: Self.bridgeToolResponse(from: projected.response),
            connectionReceipt: Self.bridgeReceipt(from: projected.connectionReceipt),
            completedCallCount: projected.completedCallCount,
            dispatchedCallCount: projected.dispatchedCallCount,
            actionFailure: projected.actionFailure)
    }

    static func browserChannel(from rawChannel: String?) throws -> BrowserMCPChannel? {
        guard let rawChannel else { return nil }
        guard let channel = BrowserMCPChannel(rawValue: rawChannel) else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "The browser request has an invalid channel.",
                hint: "Use one of: stable, beta, dev, or canary.")
        }
        return channel
    }

    private static func browserTargetLockedFailure() -> DesktopActionFailure {
        .preDispatchRefusal(
            reason: .transportSessionUnavailable,
            message: BrowserMCPConnectionError.targetLocked.localizedDescription,
            hint: "Disconnect the current browser connection before selecting another channel or endpoint.",
            standardErrorCode: .browserTargetLocked)
    }

    private static func bridgeStatus(from status: BrowserMCPStatus) -> PeekabooBridgeBrowserStatus {
        PeekabooBridgeBrowserStatus(
            isConnected: status.isConnected,
            toolCount: status.toolCount,
            detectedBrowsers: status.detectedBrowsers.map {
                PeekabooBridgeBrowserInfo(
                    name: $0.name,
                    bundleIdentifier: $0.bundleIdentifier,
                    processIdentifier: $0.processIdentifier,
                    processStartIdentity: $0.processStartIdentity,
                    version: $0.version,
                    channel: $0.channel.rawValue)
            },
            connectionReceipt: status.connectionReceipt.map(self.bridgeReceipt),
            error: status.error)
    }

    private static func bridgeReceipt(
        from receipt: BrowserMCPConnectionReceipt) -> PeekabooBridgeBrowserConnectionReceipt
    {
        PeekabooBridgeBrowserConnectionReceipt(
            channel: receipt.channel?.rawValue,
            processIdentifier: receipt.processIdentifier,
            processStartIdentity: receipt.processStartIdentity,
            bundleIdentifier: receipt.bundleIdentifier,
            browserURL: receipt.browserURL,
            webSocketDebuggerURL: receipt.webSocketDebuggerURL,
            devToolsBrowserID: receipt.devToolsBrowserID,
            browserVersion: receipt.browserVersion,
            protocolVersion: receipt.protocolVersion)
    }

    private static func browserReceipt(
        from receipt: PeekabooBridgeBrowserConnectionReceipt) throws -> BrowserMCPConnectionReceipt
    {
        let channel: BrowserMCPChannel?
        if let rawChannel = receipt.channel {
            guard let parsedChannel = BrowserMCPChannel(rawValue: rawChannel) else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .invalidRequest,
                    message: "The expected browser connection receipt has an invalid channel.",
                    hint: "Refresh browser status and retry with its exact connection receipt.")
            }
            channel = parsedChannel
        } else {
            channel = nil
        }
        return BrowserMCPConnectionReceipt(
            channel: channel,
            processIdentifier: receipt.processIdentifier,
            processStartIdentity: receipt.processStartIdentity,
            bundleIdentifier: receipt.bundleIdentifier,
            browserURL: receipt.browserURL,
            webSocketDebuggerURL: receipt.webSocketDebuggerURL,
            devToolsBrowserID: receipt.devToolsBrowserID,
            browserVersion: receipt.browserVersion,
            protocolVersion: receipt.protocolVersion)
    }

    private static func bridgeToolResponse(from response: ToolResponse) throws -> PeekabooBridgeBrowserToolResponse {
        let content = try response.content.map { try PeekabooBridgeJSONValue.fromCodable($0) }
        return try PeekabooBridgeBrowserToolResponse(
            content: content,
            isError: response.isError,
            meta: response.meta.map { try PeekabooBridgeJSONValue.fromCodable($0) })
    }

    private static func bridgeToolResponse(
        from result: BrowserMCPExecutionResult) throws -> PeekabooBridgeBrowserToolResponse
    {
        let response = try self.bridgeToolResponse(from: result.response)
        return PeekabooBridgeBrowserToolResponse(
            content: response.content,
            isError: response.isError,
            meta: response.meta,
            connectionReceipt: self.bridgeReceipt(from: result.connectionReceipt),
            completedCallCount: result.completedCallCount,
            dispatchedCallCount: result.dispatchedCallCount,
            actionFailure: result.actionFailure)
    }

    private static func bridgeBrowserRefusalResponse(
        _ failure: DesktopActionFailure) -> PeekabooBridgeBrowserToolResponse
    {
        PeekabooBridgeBrowserToolResponse(
            content: [],
            isError: true,
            meta: nil,
            actionFailure: failure)
    }
}

@MainActor
extension PeekabooServices: PeekabooBridgeBrowserCapabilityNamespaceProviding {
    public var supportsBrowserCapabilityNamespaces: Bool {
        self.browser is BrowserMCPService
    }

    public var supportsNativeBrowserWindowBinding: Bool {
        guard let browser = self.browser as? BrowserMCPService else { return false }
        return browser.supportsNativeBrowserConnectionBinding
    }

    public func prepareBrowserCapabilityNamespaceRuntime() throws {
        guard self.browserCapabilityNamespaceRuntime == nil else { return }
        self.browserCapabilityNamespaceRuntime = try BrowserMCPScopedNamespaceRuntime(context: MCPToolContext(
            services: self,
            executionPolicy: .backgroundOnly))
    }

    public func openBrowserCapabilityNamespace(namespaceID: UUID) async throws {
        guard let runtime = self.browserCapabilityNamespaceRuntime else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "The local browser namespace runtime is unavailable")
        }
        do {
            try runtime.open(.init(rawValue: namespaceID))
        } catch let error as BrowserMCPScopedNamespaceRuntimeError {
            throw Self.browserCapabilityNamespaceRuntimeRefusal(error, mutatesDesktop: false)
        }
    }

    public func executeBrowserCapabilityNamespace(
        namespaceID: UUID,
        request: PeekabooBridgeBrowserCapabilityNamespaceRequest) async throws
        -> PeekabooBridgeBrowserCapabilityNamespaceServiceResult
    {
        guard let runtime = self.browserCapabilityNamespaceRuntime else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "The local browser namespace runtime is unavailable")
        }
        let arguments = ToolArguments(raw: request.toolArguments.mapValues { $0.toAny() })
        let policy: BrowserMCPScopedNamespaceExecutionPolicy = switch request.executionMode {
        case .backgroundOnly:
            .backgroundOnly
        case .foregroundAllowed:
            .explicitlyForegroundAllowed
        }
        let result: BrowserMCPScopedNamespaceExecutionResult
        do {
            result = try await runtime.execute(
                in: .init(rawValue: namespaceID),
                arguments: arguments,
                policy: policy)
        } catch let error as BrowserMCPScopedNamespaceRuntimeError {
            throw Self.browserCapabilityNamespaceRuntimeRefusal(
                error,
                mutatesDesktop: !request.isReadOnly)
        }
        let response = result.response
        let nativeReceipt = result.nativeWindowReceipt.map {
            PeekabooBridgeBrowserNativeWindowReceipt(
                pageReference: $0.pageReference,
                processIdentifier: $0.processIdentifier,
                processStartIdentityDecimal: String($0.processStartIdentity),
                windowID: $0.windowID,
                bounds: $0.bounds)
        }
        let bridgeResponse = try PeekabooBridgeBrowserCapabilityNamespaceActionResponse(
            content: response.content.map { try PeekabooBridgeJSONValue.fromCodable($0) },
            isError: response.isError,
            meta: response.meta.map { try PeekabooBridgeJSONValue.fromCodable($0) },
            structuredContent: response.structuredContent.map { try PeekabooBridgeJSONValue.fromCodable($0) },
            nativeWindowReceipt: nativeReceipt)
        return PeekabooBridgeBrowserCapabilityNamespaceServiceResult(
            response: bridgeResponse,
            targetIdentity: result.targetIdentity,
            outcome: result.outcome)
    }

    public func closeBrowserCapabilityNamespace(namespaceID: UUID) async throws {
        guard let runtime = self.browserCapabilityNamespaceRuntime else { return }
        do {
            try await runtime.close(.init(rawValue: namespaceID))
        } catch let error as BrowserMCPScopedNamespaceRuntimeError {
            throw Self.browserCapabilityNamespaceRuntimeRefusal(error, mutatesDesktop: false)
        }
    }

    public func closeAllBrowserCapabilityNamespaces() async {
        guard let runtime = self.browserCapabilityNamespaceRuntime else { return }
        await runtime.closeAll()
    }

    public func beginNextBrowserCapabilityNamespaceGeneration() {
        self.browserCapabilityNamespaceRuntime?.beginNextHostGeneration()
    }

    private static func browserCapabilityNamespaceRuntimeRefusal(
        _ error: BrowserMCPScopedNamespaceRuntimeError,
        mutatesDesktop: Bool) -> PeekabooBridgeErrorEnvelope
    {
        let code: PeekabooBridgeErrorCode
        let reason: DesktopActionOutcome.RefusalReason
        switch error {
        case .namespaceUnknown, .namespaceClosing, .namespaceEnded:
            code = .notFound
            reason = .targetUnavailable
        case .namespaceAlreadyExists:
            code = .invalidRequest
            reason = .invalidRequest
        case .localExecutionRequired, .localBrowserServiceRequired, .scopedSessionUnavailable:
            code = .operationNotSupported
            reason = .runtimeIncompatible
        }
        guard mutatesDesktop else {
            return PeekabooBridgeErrorEnvelope(code: code, message: error.localizedDescription)
        }
        return PeekabooBridgeErrorEnvelope(
            code: code,
            actionFailure: .preDispatchRefusal(
                route: .bridge,
                reason: reason,
                message: error.localizedDescription,
                hint: reason == .targetUnavailable
                    ? "Create a new browser capability namespace before retrying."
                    : "Update and relaunch the on-demand Peekaboo host before retrying."))
    }
}

extension PeekabooBridgeJSONValue {
    static func fromCodable(_ value: some Encodable) throws -> PeekabooBridgeJSONValue {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        return try self.fromAny(object)
    }

    static func fromAny(_ value: Any) throws -> PeekabooBridgeJSONValue {
        switch value {
        case is NSNull:
            return .null
        case let value as Bool:
            return .bool(value)
        case let value as Int:
            return .int(value)
        case let value as Double:
            return .double(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            let double = value.doubleValue
            if double.rounded() == double {
                return .int(value.intValue)
            }
            return .double(double)
        case let value as String:
            return .string(value)
        case let value as [Any]:
            return try .array(value.map { try self.fromAny($0) })
        case let value as [String: Any]:
            return try .object(value.mapValues { try self.fromAny($0) })
        default:
            return .string(String(describing: value))
        }
    }

    func toAny() -> Any {
        switch self {
        case .null:
            NSNull()
        case let .bool(value):
            value
        case let .int(value):
            value
        case let .double(value):
            value
        case let .string(value):
            value
        case let .array(value):
            value.map { $0.toAny() }
        case let .object(value):
            value.mapValues { $0.toAny() }
        }
    }
}
