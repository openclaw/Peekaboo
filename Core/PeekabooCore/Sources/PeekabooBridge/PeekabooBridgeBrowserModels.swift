import Foundation

public struct PeekabooBridgeBrowserInfo: Codable, Sendable, Equatable {
    public let name: String
    public let bundleIdentifier: String
    public let processIdentifier: Int32
    public let version: String?
    public let channel: String

    public init(
        name: String,
        bundleIdentifier: String,
        processIdentifier: Int32,
        version: String?,
        channel: String)
    {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
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

public struct PeekabooBridgeBrowserChannelRequest: Codable, Sendable, Equatable {
    public let channel: String?
    public let browserURL: String?

    public init(channel: String? = nil, browserURL: String? = nil) {
        self.channel = channel
        self.browserURL = browserURL
    }
}

public struct PeekabooBridgeBrowserExecuteRequest: Codable, Sendable, Equatable {
    public let toolName: String
    public let arguments: [String: PeekabooBridgeJSONValue]
    public let channel: String?
    public let calls: [PeekabooBridgeBrowserToolCall]?

    public init(
        toolName: String,
        arguments: [String: PeekabooBridgeJSONValue],
        channel: String? = nil)
    {
        self.toolName = toolName
        self.arguments = arguments
        self.channel = channel
        self.calls = nil
    }

    public init(calls: [PeekabooBridgeBrowserToolCall], channel: String? = nil) {
        self.toolName = calls.first?.toolName ?? ""
        self.arguments = calls.first?.arguments ?? [:]
        self.channel = channel
        self.calls = calls
    }

    public var resolvedCalls: [PeekabooBridgeBrowserToolCall] {
        self.calls ?? [PeekabooBridgeBrowserToolCall(toolName: self.toolName, arguments: self.arguments)]
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

    public init(content: [PeekabooBridgeJSONValue], isError: Bool, meta: PeekabooBridgeJSONValue?) {
        self.content = content
        self.isError = isError
        self.meta = meta
    }
}
