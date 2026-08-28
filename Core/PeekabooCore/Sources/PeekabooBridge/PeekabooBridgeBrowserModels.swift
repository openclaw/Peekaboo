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

public enum PeekabooBridgeBrowserStatusObservation: String, Codable, Sendable, Equatable {
    case confirmed
    case indeterminate
}

public struct PeekabooBridgeBrowserStatus: Codable, Sendable, Equatable {
    public let isConnected: Bool
    public let toolCount: Int
    public let detectedBrowsers: [PeekabooBridgeBrowserInfo]
    public let connectionReceipt: PeekabooBridgeBrowserConnectionReceipt?
    public let error: String?
    /// Opaque provider-child generation. Present only for caller-scoped protocol-1.38 sessions.
    public let providerSessionEpoch: UUID?
    public let observation: PeekabooBridgeBrowserStatusObservation?

    public init(
        isConnected: Bool,
        toolCount: Int,
        detectedBrowsers: [PeekabooBridgeBrowserInfo],
        connectionReceipt: PeekabooBridgeBrowserConnectionReceipt? = nil,
        error: String? = nil,
        providerSessionEpoch: UUID? = nil,
        observation: PeekabooBridgeBrowserStatusObservation? = nil)
    {
        self.isConnected = isConnected
        self.toolCount = toolCount
        self.detectedBrowsers = detectedBrowsers
        self.connectionReceipt = connectionReceipt
        self.error = error
        self.providerSessionEpoch = providerSessionEpoch
        self.observation = observation
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
              self.processStartIdentityDecimal == String(processStartIdentity)
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
              self.channel == nil || self.canonicalChannelIdentity != nil,
              self.hasCanonicalDevToolsIdentity
        else {
            return false
        }
        return true
    }

    var isCanonicalProcessBoundTarget: Bool {
        guard let channelIdentity = self.canonicalChannelIdentity,
              self.localProcessIdentity != nil,
              self.bundleIdentifier == channelIdentity.bundleIdentifier,
              self.hasCanonicalDevToolsIdentity
        else {
            return false
        }
        return true
    }

    var isCanonicalLocalProcessTarget: Bool {
        guard let channelIdentity = self.canonicalChannelIdentity else { return false }
        return self.localProcessIdentity != nil &&
            self.bundleIdentifier == channelIdentity.bundleIdentifier &&
            self.browserURL == nil &&
            self.webSocketDebuggerURL == nil &&
            self.devToolsBrowserID == nil &&
            self.protocolVersion == nil
    }

    private var hasCanonicalDevToolsIdentity: Bool {
        guard let browserURL = self.browserURL,
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

    public var isCanonicalTarget: Bool {
        self.isCanonicalProcessBoundTarget || self.isCanonicalExternalTarget ||
            self.isCanonicalLocalProcessTarget
    }

    var isCanonicalExecutionTarget: Bool {
        self.isCanonicalProcessBoundTarget || self.isCanonicalExternalTarget
    }

    func matchesConnectRequest(_ request: PeekabooBridgeBrowserChannelRequest) -> Bool {
        guard request.channel.map({ $0 == self.channel }) ?? true else { return false }
        guard let requestedBrowserURL = request.browserURL else {
            return self.isCanonicalProcessBoundTarget
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

    private var canonicalChannelIdentity: ChromeChannelIdentity? {
        guard let channel,
              let identity = ChromeChannelIdentity(rawValue: channel),
              channel == identity.rawValue
        else { return nil }
        return identity
    }
}

public struct PeekabooBridgeBrowserChannelRequest: Codable, Sendable, Equatable {
    public let channel: String?
    public let browserURL: String?
    /// Explicit opt-in for one short-lived, receipt-bound cross-process bootstrap grant.
    public let requestsHandoff: Bool
    /// Opaque caller-scoped browser child. Omitted only by legacy/root CLI operations.
    public let sessionID: UUID?

    public init(
        channel: String? = nil,
        browserURL: String? = nil,
        requestsHandoff: Bool = false,
        sessionID: UUID? = nil)
    {
        self.channel = channel
        self.browserURL = browserURL
        self.requestsHandoff = requestsHandoff
        self.sessionID = sessionID
    }

    private enum CodingKeys: String, CodingKey {
        case channel
        case browserURL
        case requestsHandoff
        case sessionID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.channel = try container.decodeIfPresent(String.self, forKey: .channel)
        self.browserURL = try container.decodeIfPresent(String.self, forKey: .browserURL)
        self.requestsHandoff = try container.decodeIfPresent(Bool.self, forKey: .requestsHandoff) ?? false
        self.sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.channel, forKey: .channel)
        try container.encodeIfPresent(self.browserURL, forKey: .browserURL)
        if self.requestsHandoff {
            try container.encode(true, forKey: .requestsHandoff)
        }
        try container.encodeIfPresent(self.sessionID, forKey: .sessionID)
    }
}

public enum PeekabooBridgeBrowserExecutionConnectionPolicy: String, Codable, Sendable, Equatable {
    case requireExistingLiveReceipt = "require_existing_live_receipt"
}

public struct PeekabooBridgeBrowserElementPreflight: Codable, Sendable, Equatable {
    public let providerPageID: Int
    public let providerUIDs: [String]

    public init(providerPageID: Int, providerUIDs: [String]) {
        self.providerPageID = providerPageID
        self.providerUIDs = providerUIDs
    }

    public var isCanonical: Bool {
        self.providerPageID >= 0 && self.providerPageID <= Int(Int32.max) &&
            !self.providerUIDs.isEmpty &&
            self.providerUIDs.count <= 4096 &&
            self.providerUIDs == Array(Set(self.providerUIDs)).sorted() &&
            self.providerUIDs.allSatisfy { uid in
                !uid.isEmpty && uid.utf8.count <= 1024 &&
                    uid.unicodeScalars.allSatisfy { !CharacterSet.whitespacesAndNewlines.contains($0) }
            }
    }
}

public struct PeekabooBridgeBrowserExecuteRequest: Codable, Sendable, Equatable {
    public let toolName: String
    public let arguments: [String: PeekabooBridgeJSONValue]
    public let channel: String?
    public let calls: [PeekabooBridgeBrowserToolCall]?
    public let expectedConnectionReceipt: PeekabooBridgeBrowserConnectionReceipt?
    public let connectionPolicy: PeekabooBridgeBrowserExecutionConnectionPolicy?
    public let sessionID: UUID?
    public let expectedProviderSessionEpoch: UUID?
    public let elementPreflight: PeekabooBridgeBrowserElementPreflight?

    public init(
        toolName: String,
        arguments: [String: PeekabooBridgeJSONValue],
        channel: String? = nil,
        expectedConnectionReceipt: PeekabooBridgeBrowserConnectionReceipt? = nil,
        connectionPolicy: PeekabooBridgeBrowserExecutionConnectionPolicy? = nil,
        sessionID: UUID? = nil,
        expectedProviderSessionEpoch: UUID? = nil,
        elementPreflight: PeekabooBridgeBrowserElementPreflight? = nil)
    {
        self.toolName = toolName
        self.arguments = arguments
        self.channel = channel
        self.calls = nil
        self.expectedConnectionReceipt = expectedConnectionReceipt
        self.connectionPolicy = connectionPolicy
        self.sessionID = sessionID
        self.expectedProviderSessionEpoch = expectedProviderSessionEpoch
        self.elementPreflight = elementPreflight
    }

    public init(
        calls: [PeekabooBridgeBrowserToolCall],
        channel: String? = nil,
        expectedConnectionReceipt: PeekabooBridgeBrowserConnectionReceipt? = nil,
        connectionPolicy: PeekabooBridgeBrowserExecutionConnectionPolicy? = nil,
        sessionID: UUID? = nil,
        expectedProviderSessionEpoch: UUID? = nil,
        elementPreflight: PeekabooBridgeBrowserElementPreflight? = nil)
    {
        self.toolName = calls.first?.toolName ?? ""
        self.arguments = calls.first?.arguments ?? [:]
        self.channel = channel
        self.calls = calls
        self.expectedConnectionReceipt = expectedConnectionReceipt
        self.connectionPolicy = connectionPolicy
        self.sessionID = sessionID
        self.expectedProviderSessionEpoch = expectedProviderSessionEpoch
        self.elementPreflight = elementPreflight
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

    /// Canonical classification used by Bridge and provider adapters to select receipt-bound read routing.
    public var isReadOnly: Bool {
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

    func binding(
        to receipt: PeekabooBridgeBrowserConnectionReceipt,
        providerSessionEpoch: UUID? = nil) -> Self
    {
        let resolvedProviderSessionEpoch = providerSessionEpoch ?? self.expectedProviderSessionEpoch
        if let calls {
            return Self(
                calls: calls,
                channel: self.channel,
                expectedConnectionReceipt: receipt,
                connectionPolicy: .requireExistingLiveReceipt,
                sessionID: self.sessionID,
                expectedProviderSessionEpoch: resolvedProviderSessionEpoch,
                elementPreflight: self.elementPreflight)
        }
        return Self(
            toolName: self.toolName,
            arguments: self.arguments,
            channel: self.channel,
            expectedConnectionReceipt: receipt,
            connectionPolicy: .requireExistingLiveReceipt,
            sessionID: self.sessionID,
            expectedProviderSessionEpoch: resolvedProviderSessionEpoch,
            elementPreflight: self.elementPreflight)
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
    public let structuredContent: PeekabooBridgeJSONValue?
    public let connectionReceipt: PeekabooBridgeBrowserConnectionReceipt?
    public let completedCallCount: Int?
    public let dispatchedCallCount: Int?
    public let actionFailure: DesktopActionFailure?
    public let providerSessionEpoch: UUID?

    public init(
        content: [PeekabooBridgeJSONValue],
        isError: Bool,
        meta: PeekabooBridgeJSONValue?,
        structuredContent: PeekabooBridgeJSONValue? = nil,
        connectionReceipt: PeekabooBridgeBrowserConnectionReceipt? = nil,
        completedCallCount: Int? = nil,
        dispatchedCallCount: Int? = nil,
        actionFailure: DesktopActionFailure? = nil,
        providerSessionEpoch: UUID? = nil)
    {
        self.content = content
        self.isError = isError
        self.meta = meta
        self.structuredContent = structuredContent
        self.connectionReceipt = connectionReceipt
        self.completedCallCount = completedCallCount
        self.dispatchedCallCount = dispatchedCallCount
        self.actionFailure = actionFailure
        self.providerSessionEpoch = providerSessionEpoch
    }
}

/// Internal service result that binds one response to the connection used for dispatch.
public struct PeekabooBridgeBrowserExecutionResult: Sendable, Equatable {
    public let response: PeekabooBridgeBrowserToolResponse
    public let connectionReceipt: PeekabooBridgeBrowserConnectionReceipt
    public let completedCallCount: Int
    public let dispatchedCallCount: Int
    public let actionFailure: DesktopActionFailure?
    public let providerSessionEpoch: UUID?

    public init(
        response: PeekabooBridgeBrowserToolResponse,
        connectionReceipt: PeekabooBridgeBrowserConnectionReceipt,
        completedCallCount: Int,
        dispatchedCallCount: Int,
        actionFailure: DesktopActionFailure? = nil,
        providerSessionEpoch: UUID? = nil)
    {
        precondition(completedCallCount >= 0)
        precondition(dispatchedCallCount >= completedCallCount)
        // Execution metadata has one owner here. The Bridge handler validates these outer fields
        // and projects them into the wire response only after it has canonicalized the result.
        self.response = PeekabooBridgeBrowserToolResponse(
            content: response.content,
            isError: response.isError,
            meta: response.meta,
            structuredContent: response.structuredContent)
        self.connectionReceipt = connectionReceipt
        self.completedCallCount = completedCallCount
        self.dispatchedCallCount = dispatchedCallCount
        self.actionFailure = actionFailure
        self.providerSessionEpoch = providerSessionEpoch
    }
}
