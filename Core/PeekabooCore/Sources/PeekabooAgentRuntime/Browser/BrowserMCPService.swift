import AppKit
import Foundation
import MCP
import TachikomaMCP

public struct BrowserMCPStatus: Sendable {
    public let isConnected: Bool
    public let toolCount: Int
    public let detectedBrowsers: [DetectedBrowser]
    public let error: String?

    public init(isConnected: Bool, toolCount: Int, detectedBrowsers: [DetectedBrowser], error: String? = nil) {
        self.isConnected = isConnected
        self.toolCount = toolCount
        self.detectedBrowsers = detectedBrowsers
        self.error = error
    }
}

public struct DetectedBrowser: Sendable {
    public let name: String
    public let bundleIdentifier: String
    public let processIdentifier: Int32
    public let version: String?
    public let channel: BrowserMCPChannel

    public init(
        name: String,
        bundleIdentifier: String,
        processIdentifier: Int32,
        version: String?,
        channel: BrowserMCPChannel)
    {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.version = version
        self.channel = channel
    }
}

public enum BrowserMCPChannel: String, Sendable, CaseIterable {
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
    func disconnect() async
    @MainActor
    func execute(toolName: String, arguments: [String: Any], channel: BrowserMCPChannel?) async throws -> ToolResponse
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
        try await self.resolvedSessionManager().connect(channel: channel)
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

    public static func chromeDevToolsConfig(
        channel: BrowserMCPChannel?,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> MCPServerConfig
    {
        let resolvedChannel = channel ?? .stable
        var args = [
            "-y",
            "chrome-devtools-mcp@1.6.0",
            "--experimentalPageIdRouting",
        ]
        let description: String

        if let browserURL = environment["PEEKABOO_BROWSER_MCP_BROWSER_URL"], !browserURL.isEmpty {
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
            autoReconnect: true,
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
