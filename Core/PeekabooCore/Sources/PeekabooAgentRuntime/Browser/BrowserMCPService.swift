import AppKit
import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooFoundation
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

/// One browser response paired with the exact persistent connection that dispatched it.
///
/// Callers that need target attribution must use the receipt-bound execution API instead of
/// inferring the target from a status read performed before an unpinned call.
public struct BrowserMCPExecutionResult: Sendable {
    public let response: ToolResponse
    public let connectionReceipt: BrowserMCPConnectionReceipt
    /// Foreground setup performed implicitly before the requested calls.
    let connectionOutcome: DesktopActionOutcome?
    public let completedCallCount: Int
    public let dispatchedCallCount: Int
    public let actionFailure: DesktopActionFailure?
    let failureStage: BrowserMCPExecutionFailureStage?
    let providerReturnedError: Bool

    public init(
        response: ToolResponse,
        connectionReceipt: BrowserMCPConnectionReceipt,
        completedCallCount: Int,
        dispatchedCallCount: Int,
        actionFailure: DesktopActionFailure? = nil)
    {
        precondition(completedCallCount >= 0)
        precondition(dispatchedCallCount >= completedCallCount)
        self.response = response
        self.connectionReceipt = connectionReceipt
        self.connectionOutcome = nil
        self.completedCallCount = completedCallCount
        self.dispatchedCallCount = dispatchedCallCount
        self.actionFailure = actionFailure
        self.failureStage = nil
        self.providerReturnedError = false
    }

    init(
        response: ToolResponse,
        connectionReceipt: BrowserMCPConnectionReceipt,
        connectionOutcome: DesktopActionOutcome? = nil,
        completedCallCount: Int,
        dispatchedCallCount: Int,
        actionFailure: DesktopActionFailure?,
        failureStage: BrowserMCPExecutionFailureStage?,
        providerReturnedError: Bool = false)
    {
        precondition(completedCallCount >= 0)
        precondition(dispatchedCallCount >= completedCallCount)
        self.response = response
        self.connectionReceipt = connectionReceipt
        self.connectionOutcome = connectionOutcome
        self.completedCallCount = completedCallCount
        self.dispatchedCallCount = dispatchedCallCount
        self.actionFailure = actionFailure
        self.failureStage = failureStage
        self.providerReturnedError = providerReturnedError
    }
}

enum BrowserMCPExecutionFailureStage: Sendable, Equatable {
    case call(index: Int)
    case connectionValidation
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

public enum BrowserMCPExecutionConnectionPolicy: Sendable, Equatable {
    case allowAutoConnect
    case requireExistingLiveReceipt
}

enum BrowserMCPLaunchTarget: Sendable, Equatable {
    case exactWebSocket(String)
    case isolated(BrowserMCPChannel)
    case autoConnect(BrowserMCPChannel)
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
    @MainActor
    func executeSequence(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        expectedConnectionReceipt: BrowserMCPConnectionReceipt) async throws -> BrowserMCPExecutionResult
}

/// Additive browser client surface for callers that need canonical desktop-action semantics.
///
/// Legacy clients can continue conforming only to ``BrowserMCPClientProviding``. Receipt-aware
/// clients implement this protocol so callers do not have to infer retry safety from MCP text.
public protocol BrowserMCPActionResultProviding: BrowserMCPClientProviding {
    @MainActor
    func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?) async throws -> DesktopActionResult<ToolResponse>
    @MainActor
    func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        connectionPolicy: BrowserMCPExecutionConnectionPolicy) async throws -> DesktopActionResult<ToolResponse>
}

public protocol BrowserMCPConnectionResultProviding: BrowserMCPClientProviding {
    @MainActor
    func connectWithOutcome(
        channel: BrowserMCPChannel?,
        browserURL: String?) async throws -> DesktopActionResult<BrowserMCPStatus>
}

extension BrowserMCPActionResultProviding {
    @MainActor
    public func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        connectionPolicy: BrowserMCPExecutionConnectionPolicy) async throws -> DesktopActionResult<ToolResponse>
    {
        guard connectionPolicy == .allowAutoConnect else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .operationUnsupported,
                message: "The browser provider cannot enforce existing-connection-only execution.",
                hint: "Update the runtime host before retrying this background-only browser action.")
        }
        return try await self.executeSequenceWithOutcome(calls, channel: channel)
    }
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

    @MainActor
    public func executeSequence(
        _: [BrowserMCPMappedCall],
        channel _: BrowserMCPChannel?,
        expectedConnectionReceipt _: BrowserMCPConnectionReceipt) async throws -> BrowserMCPExecutionResult
    {
        throw BrowserMCPConnectionError.receiptBindingUnsupported
    }
}

public final class BrowserMCPService: BrowserMCPClientProviding, BrowserMCPActionResultProviding,
    BrowserMCPConnectionResultProviding, @unchecked Sendable
{
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
    init(sessionManager: BrowserMCPSessionManager) {
        self.sessionManager = sessionManager
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
    public func connectWithOutcome(
        channel: BrowserMCPChannel? = nil,
        browserURL: String?) async throws -> DesktopActionResult<BrowserMCPStatus>
    {
        try await self.resolvedSessionManager().connectWithOutcome(
            channel: channel,
            browserURL: browserURL)
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

    @MainActor
    public func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?) async throws -> DesktopActionResult<ToolResponse>
    {
        try await self.executeSequenceWithOutcome(
            calls,
            channel: channel,
            connectionPolicy: .requireExistingLiveReceipt)
    }

    @MainActor
    public func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        connectionPolicy: BrowserMCPExecutionConnectionPolicy) async throws -> DesktopActionResult<ToolResponse>
    {
        let manager = self.resolvedSessionManager()
        let semantics = calls.map(Self.actionSemantics)
        let plannedMutationCount = semantics.count(where: { $0 == .mutating })
        let result: BrowserMCPExecutionResult
        if plannedMutationCount == 0 {
            result = try await manager.executeSequenceResult(
                calls,
                channel: channel,
                connectionPolicy: connectionPolicy)
        } else {
            switch connectionPolicy {
            case .allowAutoConnect:
                let status = try await manager.statusForExecution(channel: channel)
                if status.isConnected, let receipt = status.connectionReceipt {
                    do {
                        result = try await manager.executeSequence(
                            calls,
                            channel: channel,
                            expectedConnectionReceipt: receipt)
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
                } else {
                    result = try await manager.executeSequenceResult(
                        calls,
                        channel: channel,
                        connectionPolicy: .allowAutoConnect)
                }
            case .requireExistingLiveReceipt:
                let status: BrowserMCPStatus
                do {
                    status = try await manager.statusForExecution(channel: channel)
                } catch let error as CancellationError {
                    throw BrowserMCPSessionManager.preDispatchFailure(error)
                }
                guard status.isConnected, let receipt = status.connectionReceipt else {
                    throw DesktopActionFailure.preDispatchRefusal(
                        reason: .targetUnavailable,
                        message: "Browser execution requires a live exact connection receipt.",
                        hint: "Connect the intended browser and retry.")
                }
                do {
                    result = try await manager.executeSequence(
                        calls,
                        channel: channel,
                        expectedConnectionReceipt: receipt)
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
            }
        }
        let projected = try result.projectingMutationProgress(for: calls)
        let executionOutcome: DesktopActionOutcome? = if plannedMutationCount > 0 {
            projected.actionFailure?.outcome ?? Self.successOutcome(
                dispatchedCallCount: plannedMutationCount)
        } else if projected.connectionOutcome != nil {
            projected.actionFailure?.outcome
        } else {
            nil
        }
        let outcome = Self.combinedExecutionOutcome(
            connection: projected.connectionOutcome,
            execution: executionOutcome)
        let publishesExecutionEvidence = outcome != nil ||
            (!projected.response.isError && projected.actionFailure == nil)
        let payload = if publishesExecutionEvidence {
            BrowserMCPExecutionEvidence.attaching(
                to: projected.response,
                connectionReceipt: projected.connectionReceipt,
                completedCallCount: plannedMutationCount == 0
                    ? result.completedCallCount
                    : projected.completedCallCount,
                dispatchedCallCount: plannedMutationCount == 0
                    ? result.dispatchedCallCount
                    : projected.dispatchedCallCount)
        } else {
            projected.response
        }
        return DesktopActionResult(
            payload: payload,
            outcome: outcome)
    }

    @MainActor
    public func executeSequence(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        expectedConnectionReceipt: BrowserMCPConnectionReceipt) async throws -> BrowserMCPExecutionResult
    {
        try await self.resolvedSessionManager().executeSequence(
            calls,
            channel: channel,
            expectedConnectionReceipt: expectedConnectionReceipt)
    }

    public static func chromeDevToolsConfig(
        channel: BrowserMCPChannel?,
        webSocketEndpoint: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> MCPServerConfig
    {
        let resolvedChannel = channel ?? .stable
        let target: BrowserMCPLaunchTarget
        if let webSocketEndpoint, !webSocketEndpoint.isEmpty {
            target = .exactWebSocket(webSocketEndpoint)
        } else if let browserURL = environment["PEEKABOO_BROWSER_MCP_BROWSER_URL"], !browserURL.isEmpty {
            return self.chromeDevToolsConfig(
                browserURL: browserURL,
                headless: self.environmentFlag("PEEKABOO_BROWSER_MCP_HEADLESS", environment: environment))
        } else if self.environmentFlag("PEEKABOO_BROWSER_MCP_ISOLATED", environment: environment) {
            target = .isolated(resolvedChannel)
        } else {
            target = .autoConnect(resolvedChannel)
        }
        return self.chromeDevToolsConfig(
            target: target,
            headless: self.environmentFlag("PEEKABOO_BROWSER_MCP_HEADLESS", environment: environment))
    }

    private static func successOutcome(dispatchedCallCount: Int) -> DesktopActionOutcome {
        guard let unitCount = DesktopActionOutcome.DispatchUnitCount(dispatchedCallCount) else {
            preconditionFailure("A successful browser execution must dispatch at least one call")
        }
        return .dispatchedUnverified(
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: unitCount)
    }

    private static func combinedExecutionOutcome(
        connection: DesktopActionOutcome?,
        execution: DesktopActionOutcome?) -> DesktopActionOutcome?
    {
        guard let connection else { return execution }
        guard let execution else { return connection }

        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(.outcome(connection))
        let isSuccessfulExecution = switch execution.state {
        case .confirmedChange, .confirmedNoChange, .dispatchedUnverified: true
        case .partial, .suspectedNoop, .refused, .indeterminate: false
        }
        if !isSuccessfulExecution,
           let failure = DesktopActionFailure(
               outcome: execution,
               message: "Browser execution failed after implicit connection setup.")
        {
            return sequence.failure(
                combining: failure,
                message: failure.message).outcome
        }
        sequence.record(.outcome(execution))
        let resolution = sequence.successResolution()
        return resolution.outcome ?? .indeterminate(
            route: connection.route,
            evidence: .completionUnknown,
            unitCount: resolution.mutationDisposition.unitCount)
    }

    private static func actionSemantics(_ call: BrowserMCPMappedCall)
        -> BrowserMCPPageRoutingContract.ActionSemantics
    {
        BrowserMCPPageRoutingContract.actionSemantics(
            for: call.toolName,
            arguments: call.arguments) ?? .mutating
    }

    static func chromeDevToolsConfig(
        target: BrowserMCPLaunchTarget,
        headless: Bool) -> MCPServerConfig
    {
        var args = [
            "-y",
            "chrome-devtools-mcp@1.6.0",
            "--experimentalPageIdRouting",
        ]
        let description: String

        switch target {
        case let .exactWebSocket(webSocketEndpoint):
            args.append("--wsEndpoint=\(webSocketEndpoint)")
            description = "Chrome DevTools automation for an exact browser endpoint"
        case let .isolated(channel):
            args.append("--isolated")
            args.append("--channel=\(channel.rawValue)")
            description = "Chrome DevTools automation for an isolated \(channel.rawValue) Chrome profile"
        case let .autoConnect(channel):
            args.append("--auto-connect")
            args.append("--channel=\(channel.rawValue)")
            description = "Chrome DevTools automation for the running \(channel.rawValue) Chrome profile"
        }

        if headless {
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

    private static func chromeDevToolsConfig(browserURL: String, headless: Bool) -> MCPServerConfig {
        var args = [
            "-y",
            "chrome-devtools-mcp@1.6.0",
            "--experimentalPageIdRouting",
            "--browserUrl=\(browserURL)",
        ]
        if headless {
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
            description: "Chrome DevTools automation for \(browserURL)")
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
    case expectedConnectionReceiptMismatch
    case receiptBindingUnsupported
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
        case .expectedConnectionReceiptMismatch:
            "The expected browser connection changed before tool dispatch. Refresh browser status and retry."
        case .receiptBindingUnsupported:
            "This browser client cannot atomically bind execution to an exact connection receipt."
        case .targetLocked:
            "A different browser target is already connected. " +
                "Disconnect it before selecting another channel or endpoint."
        }
    }
}
