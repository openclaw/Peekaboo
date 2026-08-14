import AppKit
import Foundation
import MCP
import PeekabooAutomationKit
import TachikomaMCP

public struct BrowserMCPStatus: Sendable {
    public let isConnected: Bool
    public let toolCount: Int
    public let detectedBrowsers: [DetectedBrowser]
    public let connectionReceipt: BrowserMCPConnectionReceipt?
    public let error: String?

    public init(
        isConnected: Bool,
        toolCount: Int,
        detectedBrowsers: [DetectedBrowser],
        connectionReceipt: BrowserMCPConnectionReceipt? = nil,
        error: String? = nil)
    {
        self.isConnected = isConnected
        self.toolCount = toolCount
        self.detectedBrowsers = detectedBrowsers
        self.connectionReceipt = connectionReceipt
        self.error = error
    }
}

public struct DetectedBrowser: Sendable, Equatable {
    public let name: String
    public let bundleIdentifier: String
    public let processIdentifier: Int32
    public let processStartIdentity: UInt64?
    public let version: String?
    public let channel: BrowserMCPChannel

    public init(
        name: String,
        bundleIdentifier: String,
        processIdentifier: Int32,
        processStartIdentity: UInt64? = nil,
        version: String?,
        channel: BrowserMCPChannel)
    {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
        self.version = version
        self.channel = channel
    }
}

public struct BrowserMCPConnectionReceipt: Sendable, Equatable {
    public let channel: BrowserMCPChannel?
    public let processIdentifier: Int32?
    public let processStartIdentity: UInt64?
    public let bundleIdentifier: String?
    public let browserURL: String?
    public let webSocketDebuggerURL: String?
    public let devToolsBrowserID: String?
    public let browserVersion: String?
    public let protocolVersion: String?

    public init(
        channel: BrowserMCPChannel? = nil,
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
        self.bundleIdentifier = bundleIdentifier
        self.browserURL = browserURL
        self.webSocketDebuggerURL = webSocketDebuggerURL
        self.devToolsBrowserID = devToolsBrowserID
        self.browserVersion = browserVersion
        self.protocolVersion = protocolVersion
    }
}

public enum BrowserMCPChannel: String, Sendable, CaseIterable, Codable {
    case stable
    case beta
    case dev
    case canary

    static func infer(bundleIdentifier: String, applicationName: String) -> Self? {
        let bundle = bundleIdentifier.lowercased()
        let name = applicationName.lowercased()

        if bundle == "com.google.chrome" || name == "google chrome" {
            return .stable
        }
        if bundle.contains("chrome.beta") || name.contains("chrome beta") {
            return .beta
        }
        if bundle.contains("chrome.dev") || name.contains("chrome dev") {
            return .dev
        }
        if bundle.contains("chrome.canary") || name.contains("canary") {
            return .canary
        }
        return nil
    }
}

public protocol BrowserMCPClientProviding: AnyObject, Sendable {
    @MainActor
    func status(channel: BrowserMCPChannel?) async -> BrowserMCPStatus
    @MainActor
    func connect(channel: BrowserMCPChannel?) async throws -> BrowserMCPStatus
    @MainActor
    func connect(channel: BrowserMCPChannel?, browserURL: String?) async throws -> BrowserMCPStatus
    @MainActor
    func disconnect() async
    @MainActor
    func execute(toolName: String, arguments: [String: Any], channel: BrowserMCPChannel?) async throws -> ToolResponse
    @MainActor
    func executeSequence(_ calls: [BrowserMCPMappedCall], channel: BrowserMCPChannel?) async throws -> ToolResponse
}

extension BrowserMCPClientProviding {
    @MainActor
    public func connect(channel: BrowserMCPChannel?, browserURL: String?) async throws -> BrowserMCPStatus {
        guard browserURL == nil else {
            throw BrowserMCPConnectionError.explicitEndpointUnsupported
        }
        return try await self.connect(channel: channel)
    }

    @MainActor
    public func executeSequence(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?) async throws -> ToolResponse
    {
        guard let first = calls.first else {
            throw BrowserMCPConnectionError.connectionLost("the browser action sequence was empty")
        }
        var response = try await self.execute(
            toolName: first.toolName,
            arguments: first.arguments,
            channel: channel)
        for call in calls.dropFirst() where !response.isError {
            response = try await self.execute(
                toolName: call.toolName,
                arguments: call.arguments,
                channel: channel)
        }
        return response
    }
}

public final class BrowserMCPService: BrowserMCPClientProviding, @unchecked Sendable {
    private static let serverName = "chrome-devtools"

    @MainActor private var sessionManager: BrowserMCPSessionManager?

    public init() {
        self.sessionManager = nil
    }

    @MainActor
    public init(manager: TachikomaMCPClientManager) {
        self.sessionManager = BrowserMCPSessionManager(serverName: Self.serverName, manager: manager)
    }

    @MainActor
    public func status(channel: BrowserMCPChannel? = nil) async -> BrowserMCPStatus {
        await self.resolvedSessionManager().status(channel: channel)
    }

    @MainActor
    public func connect(channel: BrowserMCPChannel? = nil) async throws -> BrowserMCPStatus {
        try await self.connect(channel: channel, browserURL: nil)
    }

    @MainActor
    public func connect(
        channel: BrowserMCPChannel? = nil,
        browserURL: String?) async throws -> BrowserMCPStatus
    {
        try await self.resolvedSessionManager().connect(channel: channel, browserURL: browserURL)
    }

    @MainActor
    public func disconnect() async {
        await self.resolvedSessionManager().disconnect()
    }

    @MainActor
    public func execute(
        toolName: String,
        arguments: [String: Any],
        channel: BrowserMCPChannel? = nil) async throws -> ToolResponse
    {
        try await self.resolvedSessionManager().execute(
            toolName: toolName,
            arguments: arguments,
            channel: channel)
    }

    @MainActor
    public func executeSequence(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?) async throws -> ToolResponse
    {
        try await self.resolvedSessionManager().executeSequence(calls, channel: channel)
    }

    public static func chromeDevToolsConfig(
        channel: BrowserMCPChannel?,
        webSocketEndpoint: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> MCPServerConfig
    {
        let resolvedChannel = channel ?? .stable
        var args = [
            "-y",
            "chrome-devtools-mcp@1.6.0",
            "--experimentalPageIdRouting",
        ]
        let description: String

        if let webSocketEndpoint, !webSocketEndpoint.isEmpty {
            args.append("--wsEndpoint=\(webSocketEndpoint)")
            description = "Chrome DevTools automation for an exact browser endpoint"
        } else if let browserURL = environment["PEEKABOO_BROWSER_MCP_BROWSER_URL"], !browserURL.isEmpty {
            args.append("--browserUrl=\(browserURL)")
            description = "Chrome DevTools automation for \(browserURL)"
        } else if self.environmentFlag("PEEKABOO_BROWSER_MCP_ISOLATED", environment: environment) {
            args.append("--isolated")
            args.append("--channel=\(resolvedChannel.rawValue)")
            description = "Chrome DevTools automation for an isolated \(resolvedChannel.rawValue) Chrome profile"
        } else {
            args.append("--auto-connect")
            args.append("--channel=\(resolvedChannel.rawValue)")
            description = "Chrome DevTools automation for the running \(resolvedChannel.rawValue) Chrome profile"
        }

        if self.environmentFlag("PEEKABOO_BROWSER_MCP_HEADLESS", environment: environment) {
            args.append("--headless")
        }

        args.append("--no-usage-statistics")
        args.append("--no-performance-crux")

        return MCPServerConfig(
            transport: "stdio",
            command: "npx",
            args: args,
            enabled: true,
            timeout: 30,
            autoReconnect: false,
            description: description)
    }

    public static func detectRunningBrowsers(channel: BrowserMCPChannel? = nil) -> [DetectedBrowser] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard !application.isTerminated else { return nil }
            guard let name = application.localizedName else { return nil }
            guard let bundleIdentifier = application.bundleIdentifier else { return nil }
            guard let inferred = BrowserMCPChannel.infer(
                bundleIdentifier: bundleIdentifier,
                applicationName: name)
            else {
                return nil
            }
            if let channel, channel != inferred {
                return nil
            }

            return DetectedBrowser(
                name: name,
                bundleIdentifier: bundleIdentifier,
                processIdentifier: application.processIdentifier,
                processStartIdentity: SystemIdentityResolver.processStartIdentity(application.processIdentifier),
                version: self.version(for: application),
                channel: inferred)
        }
    }

    static func preferredChannel() -> BrowserMCPChannel {
        self.detectRunningBrowsers().first?.channel ?? .stable
    }

    private static func environmentFlag(_ name: String, environment: [String: String]) -> Bool {
        guard let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(value)
    }

    @MainActor
    private func resolvedSessionManager() -> BrowserMCPSessionManager {
        if let sessionManager {
            return sessionManager
        }
        let sessionManager = BrowserMCPSessionManager(serverName: Self.serverName)
        self.sessionManager = sessionManager
        return sessionManager
    }

    private static func version(for application: NSRunningApplication) -> String? {
        guard let url = application.bundleURL,
              let bundle = Bundle(url: url)
        else {
            return nil
        }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}

public enum BrowserMCPConnectionError: LocalizedError, Equatable {
    case noBrowser(BrowserMCPChannel)
    case ambiguousBrowsers(BrowserMCPChannel, [Int32])
    case processIdentityUnavailable(Int32)
    case explicitEndpointUnsupported
    case invalidEndpoint(String)
    case connectionProbeFailed(String)
    case connectionLost(String)
    case targetLocked

    public var errorDescription: String? {
        switch self {
        case let .noBrowser(channel):
            "No running \(channel.rawValue) Chrome process is available for an exact browser connection."
        case let .ambiguousBrowsers(channel, processIdentifiers):
            "Multiple \(channel.rawValue) Chrome processes are running (PIDs: " +
                processIdentifiers.sorted().map(String.init).joined(separator: ", ") +
                "). Refusing channel-only browser discovery; reconnect with one exact loopback browser URL."
        case let .processIdentityUnavailable(processIdentifier):
            "Chrome PID \(processIdentifier) has no stable process-generation receipt."
        case .explicitEndpointUnsupported:
            "This browser client cannot carry an explicit DevTools endpoint."
        case let .invalidEndpoint(reason):
            "Invalid browser_url: \(reason)"
        case let .connectionProbeFailed(reason):
            "Chrome DevTools MCP started, but its exact read-only connection probe failed: \(reason)"
        case let .connectionLost(reason):
            "The exact browser connection was lost or changed: \(reason). Disconnect and reconnect explicitly."
        case .targetLocked:
            "A different browser target is already connected. " +
                "Disconnect it before selecting another channel or endpoint."
        }
    }
}
