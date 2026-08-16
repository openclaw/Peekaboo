import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

public struct PeekabooBridgeBrowserInfo: Codable, Sendable, Equatable {
    public let name: String
    public let bundleIdentifier: String
    public let processIdentifier: Int32
    public let processStartIdentity: UInt64?
    /// Canonical decimal representation for consumers that cannot losslessly decode every UInt64 JSON number.
    public let processStartIdentityDecimal: String?
    public let version: String?
    public let channel: String

    public init(
        name: String,
        bundleIdentifier: String,
        processIdentifier: Int32,
        processStartIdentity: UInt64? = nil,
        version: String?,
        channel: String)
    {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
        self.processStartIdentityDecimal = processStartIdentity.map(String.init)
        self.version = version
        self.channel = channel
    }
}

public struct PeekabooBridgeBrowserStatus: Codable, Sendable, Equatable {
    public let isConnected: Bool
    public let toolCount: Int
    public let detectedBrowsers: [PeekabooBridgeBrowserInfo]
    public let connectionReceipt: PeekabooBridgeBrowserConnectionReceipt?
    public let error: String?

    public init(
        isConnected: Bool,
        toolCount: Int,
        detectedBrowsers: [PeekabooBridgeBrowserInfo],
        connectionReceipt: PeekabooBridgeBrowserConnectionReceipt? = nil,
        error: String? = nil)
    {
        self.isConnected = isConnected
        self.toolCount = toolCount
        self.detectedBrowsers = detectedBrowsers
        self.connectionReceipt = connectionReceipt
        self.error = error
    }
}

public struct PeekabooBridgeBrowserConnectionReceipt: Codable, Sendable, Equatable {
    public let channel: String?
    public let processIdentifier: Int32?
    public let processStartIdentity: UInt64?
    public let processStartIdentityDecimal: String?
    public let bundleIdentifier: String?
    public let browserURL: String?
    public let webSocketDebuggerURL: String?
    public let devToolsBrowserID: String?
    public let browserVersion: String?
    public let protocolVersion: String?

    public init(
        channel: String? = nil,
        processIdentifier: Int32? = nil,
        processStartIdentity: UInt64? = nil,
        bundleIdentifier: String? = nil,
        browserURL: String? = nil,
        webSocketDebuggerURL: String? = nil,
        devToolsBrowserID: String? = nil,
        browserVersion: String? = nil,
        protocolVersion: String? = nil)
    {
        self.channel = channel
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
        self.processStartIdentityDecimal = processStartIdentity.map(String.init)
        self.bundleIdentifier = bundleIdentifier
        self.browserURL = browserURL
        self.webSocketDebuggerURL = webSocketDebuggerURL
        self.devToolsBrowserID = devToolsBrowserID
        self.browserVersion = browserVersion
        self.protocolVersion = protocolVersion
    }
}

extension PeekabooBridgeBrowserConnectionReceipt {
    var localProcessIdentity: ApplicationProcessIdentity? {
        guard let processIdentifier = self.processIdentifier,
              processIdentifier > 0,
              let processStartIdentity = self.processStartIdentity,
              processStartIdentity > 0,
              self.processStartIdentityDecimal == String(processStartIdentity),
              self.browserURL == nil,
              self.webSocketDebuggerURL == nil,
              self.devToolsBrowserID == nil,
              self.protocolVersion == nil
        else {
            return nil
        }
        return .init(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity)
    }

    var isCanonicalExternalTarget: Bool {
        guard self.processIdentifier == nil,
              self.processStartIdentity == nil,
              self.processStartIdentityDecimal == nil,
              self.bundleIdentifier == nil,
              let browserURL = self.browserURL,
              Self.isNonEmpty(self.webSocketDebuggerURL),
              let webSocketDebuggerURL = self.webSocketDebuggerURL,
              let devToolsBrowserID = self.devToolsBrowserID,
              Self.isNonEmpty(devToolsBrowserID),
              Self.isNonEmpty(self.browserVersion),
              Self.isNonEmpty(self.protocolVersion),
              let endpoint = BrowserLoopbackEndpoint(browserURL: browserURL),
              endpoint.matchesWebSocketDebuggerURL(
                  webSocketDebuggerURL,
                  browserID: devToolsBrowserID)
        else {
            return false
        }
        return true
    }

    var isCanonicalTarget: Bool {
        self.localProcessIdentity != nil || self.isCanonicalExternalTarget
    }

    func matchesConnectRequest(_ request: PeekabooBridgeBrowserChannelRequest) -> Bool {
        guard request.channel.map({ $0 == self.channel }) ?? true else { return false }
        guard let requestedBrowserURL = request.browserURL else {
            return self.isCanonicalTarget
        }
        guard self.isCanonicalExternalTarget,
              let requestedEndpoint = BrowserLoopbackEndpoint(
                  browserURL: requestedBrowserURL),
              let receiptBrowserURL = self.browserURL,
              let receiptEndpoint = BrowserLoopbackEndpoint(
                  browserURL: receiptBrowserURL)
        else {
            return false
        }
        return requestedEndpoint == receiptEndpoint
    }

    private static func isNonEmpty(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

public struct PeekabooBridgeBrowserChannelRequest: Codable, Sendable, Equatable {
    public let channel: String?
    public let browserURL: String?

    public init(channel: String? = nil, browserURL: String? = nil) {
        self.channel = channel
        self.browserURL = browserURL
    }
}

public enum PeekabooBridgeBrowserExecutionConnectionPolicy: String, Codable, Sendable, Equatable {
    case requireExistingLiveReceipt = "require_existing_live_receipt"
}

public struct PeekabooBridgeBrowserExecuteRequest: Codable, Sendable, Equatable {
    public let toolName: String
    public let arguments: [String: PeekabooBridgeJSONValue]
    public let channel: String?
    public let calls: [PeekabooBridgeBrowserToolCall]?
    public let expectedConnectionReceipt: PeekabooBridgeBrowserConnectionReceipt?
    public let connectionPolicy: PeekabooBridgeBrowserExecutionConnectionPolicy?

    public init(
        toolName: String,
        arguments: [String: PeekabooBridgeJSONValue],
        channel: String? = nil,
        expectedConnectionReceipt: PeekabooBridgeBrowserConnectionReceipt? = nil,
        connectionPolicy: PeekabooBridgeBrowserExecutionConnectionPolicy? = nil)
    {
        self.toolName = toolName
        self.arguments = arguments
        self.channel = channel
        self.calls = nil
        self.expectedConnectionReceipt = expectedConnectionReceipt
        self.connectionPolicy = connectionPolicy
    }

    public init(
        calls: [PeekabooBridgeBrowserToolCall],
        channel: String? = nil,
        expectedConnectionReceipt: PeekabooBridgeBrowserConnectionReceipt? = nil,
        connectionPolicy: PeekabooBridgeBrowserExecutionConnectionPolicy? = nil)
    {
        self.toolName = calls.first?.toolName ?? ""
        self.arguments = calls.first?.arguments ?? [:]
        self.channel = channel
        self.calls = calls
        self.expectedConnectionReceipt = expectedConnectionReceipt
        self.connectionPolicy = connectionPolicy
    }

    public var resolvedCalls: [PeekabooBridgeBrowserToolCall] {
        self.calls ?? [PeekabooBridgeBrowserToolCall(toolName: self.toolName, arguments: self.arguments)]
    }

    var actionSemantics: BrowserToolActionSemantics {
        let calls = self.resolvedCalls
        guard !calls.isEmpty else { return .mutating }
        return calls.allSatisfy { call in
            BrowserToolActionSemantics.classify(toolName: call.toolName) { name in
                guard case let .bool(value)? = call.arguments[name] else { return nil }
                return value
            } == .readOnly
        } ? .readOnly : .mutating
    }

    var isReadOnly: Bool {
        self.actionSemantics == .readOnly
    }

    var mutationCallCount: Int {
        self.resolvedCalls.count { call in
            BrowserToolActionSemantics.classify(toolName: call.toolName) { name in
                guard case let .bool(value)? = call.arguments[name] else { return nil }
                return value
            } != .readOnly
        }
    }

    func binding(to receipt: PeekabooBridgeBrowserConnectionReceipt) -> Self {
        if let calls {
            return Self(
                calls: calls,
                channel: self.channel,
                expectedConnectionReceipt: receipt,
                connectionPolicy: .requireExistingLiveReceipt)
        }
        return Self(
            toolName: self.toolName,
            arguments: self.arguments,
            channel: self.channel,
            expectedConnectionReceipt: receipt,
            connectionPolicy: .requireExistingLiveReceipt)
    }
}

public struct PeekabooBridgeBrowserToolCall: Codable, Sendable, Equatable {
    public let toolName: String
    public let arguments: [String: PeekabooBridgeJSONValue]

    public init(toolName: String, arguments: [String: PeekabooBridgeJSONValue]) {
        self.toolName = toolName
        self.arguments = arguments
    }
}

public struct PeekabooBridgeBrowserToolResponse: Codable, Sendable, Equatable {
    public let content: [PeekabooBridgeJSONValue]
    public let isError: Bool
    public let meta: PeekabooBridgeJSONValue?
    public let connectionReceipt: PeekabooBridgeBrowserConnectionReceipt?
    public let completedCallCount: Int?
    public let dispatchedCallCount: Int?
    public let actionFailure: DesktopActionFailure?

    public init(
        content: [PeekabooBridgeJSONValue],
        isError: Bool,
        meta: PeekabooBridgeJSONValue?,
        connectionReceipt: PeekabooBridgeBrowserConnectionReceipt? = nil,
        completedCallCount: Int? = nil,
        dispatchedCallCount: Int? = nil,
        actionFailure: DesktopActionFailure? = nil)
    {
        self.content = content
        self.isError = isError
        self.meta = meta
        self.connectionReceipt = connectionReceipt
        self.completedCallCount = completedCallCount
        self.dispatchedCallCount = dispatchedCallCount
        self.actionFailure = actionFailure
    }
}

/// Internal service result that binds one response to the connection used for dispatch.
public struct PeekabooBridgeBrowserExecutionResult: Sendable, Equatable {
    public let response: PeekabooBridgeBrowserToolResponse
    public let connectionReceipt: PeekabooBridgeBrowserConnectionReceipt
    public let completedCallCount: Int
    public let dispatchedCallCount: Int
    public let actionFailure: DesktopActionFailure?

    public init(
        response: PeekabooBridgeBrowserToolResponse,
        connectionReceipt: PeekabooBridgeBrowserConnectionReceipt,
        completedCallCount: Int,
        dispatchedCallCount: Int,
        actionFailure: DesktopActionFailure? = nil)
    {
        precondition(completedCallCount >= 0)
        precondition(dispatchedCallCount >= completedCallCount)
        // Execution metadata has one owner here. The Bridge handler validates these outer fields
        // and projects them into the wire response only after it has canonicalized the result.
        self.response = PeekabooBridgeBrowserToolResponse(
            content: response.content,
            isError: response.isError,
            meta: response.meta)
        self.connectionReceipt = connectionReceipt
        self.completedCallCount = completedCallCount
        self.dispatchedCallCount = dispatchedCallCount
        self.actionFailure = actionFailure
    }
}
