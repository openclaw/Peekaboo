import Foundation
import MCP
import PeekabooAutomationKit
import TachikomaMCP

@MainActor
protocol BrowserMCPManaging: AnyObject {
    func hasServer(name: String) -> Bool
    func isServerConnected(name: String) async -> Bool
    func serverToolCount(name: String) async -> Int
    func addServer(name: String, config: MCPServerConfig) async throws
    func removeServer(name: String) async
    func executeTool(serverName: String, toolName: String, arguments: [String: Any]) async throws -> ToolResponse
}

extension TachikomaMCPClientManager: BrowserMCPManaging {
    func hasServer(name: String) -> Bool {
        self.getServerConfig(name: name) != nil
    }

    func serverToolCount(name: String) async -> Int {
        await self.getServerTools(name: name).count
    }
}

@MainActor
final class BrowserMCPSessionManager: @unchecked Sendable {
    typealias BrowserDetector = @MainActor (BrowserMCPChannel?) -> [DetectedBrowser]
    typealias ProcessIdentityProvider = @Sendable (Int32) -> UInt64?

    private let serverName: String
    private let manager: any BrowserMCPManaging
    private let detectedBrowsers: BrowserDetector
    private let processStartIdentity: ProcessIdentityProvider
    private let endpointResolver: BrowserMCPDevToolsEndpointResolver
    private let uploadStager: BrowserMCPUploadStager
    private let executionGate = MCPToolSnapshotExecutionGate()
    private var connectionReceipt: BrowserMCPConnectionReceipt?
    private var uploadWorkspace: BrowserMCPUploadWorkspace?
    private var activeUploadID: UUID?

    init(
        serverName: String,
        manager: any BrowserMCPManaging = TachikomaMCPClientManager(),
        detectedBrowsers: @escaping BrowserDetector = BrowserMCPService.detectRunningBrowsers,
        processStartIdentity: @escaping ProcessIdentityProvider = { processIdentifier in
            SystemIdentityResolver.processStartIdentity(processIdentifier)
        },
        endpointResolver: BrowserMCPDevToolsEndpointResolver = .live,
        uploadStager: BrowserMCPUploadStager = .live)
    {
        self.serverName = serverName
        self.manager = manager
        self.detectedBrowsers = detectedBrowsers
        self.processStartIdentity = processStartIdentity
        self.endpointResolver = endpointResolver
        self.uploadStager = uploadStager
    }

    func status(channel: BrowserMCPChannel?) async -> BrowserMCPStatus {
        let browsers = self.detectedBrowsers(channel)
        guard let receipt = self.connectionReceipt else {
            if await self.manager.isServerConnected(name: self.serverName) || self.manager
                .hasServer(name: self.serverName)
            {
                await self.manager.removeServer(name: self.serverName)
            }
            return BrowserMCPStatus(
                isConnected: false,
                toolCount: 0,
                detectedBrowsers: browsers,
                connectionReceipt: nil)
        }

        do {
            try await self.validate(receipt)
            guard await self.manager.isServerConnected(name: self.serverName) else {
                throw BrowserMCPConnectionError.connectionLost("the persistent MCP child is no longer connected")
            }
            return await BrowserMCPStatus(
                isConnected: true,
                toolCount: self.manager.serverToolCount(name: self.serverName),
                detectedBrowsers: browsers,
                connectionReceipt: receipt)
        } catch {
            await self.clearConnection()
            return BrowserMCPStatus(
                isConnected: false,
                toolCount: 0,
                detectedBrowsers: browsers,
                connectionReceipt: nil,
                error: error.localizedDescription)
        }
    }

    func connect(channel: BrowserMCPChannel?, browserURL: String? = nil) async throws -> BrowserMCPStatus {
        try await self.withExecutionGate {
            try await self.connectUnlocked(channel: channel, browserURL: browserURL)
        }
    }

    private func connectUnlocked(
        channel: BrowserMCPChannel?,
        browserURL: String? = nil) async throws -> BrowserMCPStatus
    {
        let target = try await self.resolveTarget(channel: channel, browserURL: browserURL)
        if let existing = self.connectionReceipt {
            guard existing == target.receipt else {
                throw BrowserMCPConnectionError.targetLocked
            }
            try await self.validate(existing)
            guard await self.manager.isServerConnected(name: self.serverName) else {
                await self.clearConnection()
                throw BrowserMCPConnectionError.connectionLost("the persistent MCP child exited")
            }
            return await self.status(channel: channel)
        }

        if self.manager.hasServer(name: self.serverName) {
            await self.manager.removeServer(name: self.serverName)
        }
        do {
            let uploadWorkspace = try await self.uploadStager.createWorkspace()
            var config = target.config
            config.env["TMPDIR"] = uploadWorkspace.rootPath
            self.uploadWorkspace = uploadWorkspace
            try await self.manager.addServer(name: self.serverName, config: config)
            let probe = try await self.manager.executeTool(
                serverName: self.serverName,
                toolName: "list_pages",
                arguments: [:])
            guard !probe.isError else {
                throw BrowserMCPConnectionError.connectionProbeFailed(
                    "Chrome DevTools MCP rejected list_pages")
            }
            try await self.validate(target.receipt)
            self.connectionReceipt = target.receipt
            return await self.status(channel: channel)
        } catch let error as BrowserMCPUploadStagingError {
            await self.clearConnection()
            throw error
        } catch let error as BrowserMCPConnectionError {
            await self.clearConnection()
            throw error
        } catch {
            await self.clearConnection()
            throw BrowserMCPConnectionError.connectionProbeFailed(error.localizedDescription)
        }
    }

    func disconnect() async {
        try? await self.withExecutionGate {
            await self.clearConnection()
        }
    }

    func execute(
        toolName: String,
        arguments: [String: Any],
        channel: BrowserMCPChannel?) async throws -> ToolResponse
    {
        try await self.executeSequence(
            [BrowserMCPMappedCall(toolName: toolName, arguments: arguments)],
            channel: channel)
    }

    func executeSequence(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?) async throws -> ToolResponse
    {
        try await self.withExecutionGate {
            try await self.executeSequenceUnlocked(calls, channel: channel)
        }
    }

    private func executeSequenceUnlocked(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?) async throws -> ToolResponse
    {
        guard !calls.isEmpty else {
            throw BrowserMCPConnectionError.connectionLost("the browser action sequence was empty")
        }
        if self.connectionReceipt == nil {
            _ = try await self.connectUnlocked(channel: channel)
        }
        guard let receipt = self.connectionReceipt else {
            throw BrowserMCPConnectionError.connectionLost("no exact connection receipt exists")
        }
        if let channel, channel != receipt.channel {
            throw BrowserMCPConnectionError.targetLocked
        }
        try await self.validate(receipt)
        guard await self.manager.isServerConnected(name: self.serverName) else {
            await self.clearConnection()
            throw BrowserMCPConnectionError.connectionLost("the persistent MCP child exited")
        }

        do {
            var response: ToolResponse?
            for call in calls {
                let current = try await self.execute(call)
                response = current
                if current.isError {
                    break
                }
            }
            try await self.validate(receipt)
            guard let response else {
                throw BrowserMCPConnectionError.connectionLost("the browser action sequence returned no response")
            }
            return response
        } catch let error as BrowserMCPUploadStagingError {
            throw error
        } catch is CancellationError {
            await self.clearConnection()
            throw CancellationError()
        } catch let error as BrowserMCPConnectionError {
            await self.clearConnection()
            throw error
        } catch {
            await self.clearConnection()
            throw BrowserMCPConnectionError.connectionLost(error.localizedDescription)
        }
    }

    private func execute(_ call: BrowserMCPMappedCall) async throws -> ToolResponse {
        guard call.toolName == "upload_file" else {
            return try await self.manager.executeTool(
                serverName: self.serverName,
                toolName: call.toolName,
                arguments: call.arguments)
        }
        guard let sourcePath = call.arguments["filePath"] as? String, !sourcePath.isEmpty else {
            throw BrowserMCPUploadStagingError.invalidPath("upload_file requires a non-empty filePath string")
        }

        guard let uploadWorkspace = self.uploadWorkspace else {
            throw BrowserMCPConnectionError.connectionLost("the browser upload workspace is unavailable")
        }
        let stagedUpload = try await self.uploadStager.stage(path: sourcePath, in: uploadWorkspace)
        try Task.checkCancellation()
        var stagedArguments = call.arguments
        stagedArguments["filePath"] = stagedUpload.filePath
        let uploadID = UUID()
        self.activeUploadID = uploadID
        do {
            let response = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await self.manager.executeTool(
                    serverName: self.serverName,
                    toolName: call.toolName,
                    arguments: stagedArguments)
            } onCancel: { [weak self] in
                Task { @MainActor in
                    await self?.cancelUpload(id: uploadID)
                }
            }
            try Task.checkCancellation()
            if self.activeUploadID == uploadID {
                self.activeUploadID = nil
            }
            uploadWorkspace.retain(stagedUpload)
            return response
        } catch {
            if self.activeUploadID == uploadID {
                self.activeUploadID = nil
            }
            uploadWorkspace.retain(stagedUpload)
            throw error
        }
    }

    private func cancelUpload(id: UUID) async {
        guard self.activeUploadID == id else { return }
        self.activeUploadID = nil
        await self.clearConnection()
    }

    private func resolveTarget(
        channel: BrowserMCPChannel?,
        browserURL: String?) async throws
        -> (receipt: BrowserMCPConnectionReceipt, config: MCPServerConfig)
    {
        if let browserURL {
            let endpoint = try await self.endpointResolver.resolve(browserURL)
            let receipt = BrowserMCPConnectionReceipt(
                channel: channel,
                browserURL: endpoint.browserURL,
                webSocketDebuggerURL: endpoint.webSocketDebuggerURL,
                devToolsBrowserID: endpoint.browserID,
                browserVersion: endpoint.browserVersion,
                protocolVersion: endpoint.protocolVersion)
            return (
                receipt,
                BrowserMCPService.chromeDevToolsConfig(
                    channel: channel,
                    webSocketEndpoint: endpoint.webSocketDebuggerURL))
        }

        let resolvedChannel = channel ?? BrowserMCPService.preferredChannel()
        let candidates = self.detectedBrowsers(resolvedChannel)
        guard !candidates.isEmpty else {
            throw BrowserMCPConnectionError.noBrowser(resolvedChannel)
        }
        guard candidates.count == 1, let browser = candidates.first else {
            throw BrowserMCPConnectionError.ambiguousBrowsers(
                resolvedChannel,
                candidates.map(\.processIdentifier))
        }
        guard let processStartIdentity = browser.processStartIdentity,
              self.processStartIdentity(browser.processIdentifier) == processStartIdentity
        else {
            throw BrowserMCPConnectionError.processIdentityUnavailable(browser.processIdentifier)
        }
        let receipt = BrowserMCPConnectionReceipt(
            channel: resolvedChannel,
            processIdentifier: browser.processIdentifier,
            processStartIdentity: processStartIdentity,
            bundleIdentifier: browser.bundleIdentifier,
            browserVersion: browser.version)
        return (receipt, BrowserMCPService.chromeDevToolsConfig(channel: resolvedChannel))
    }

    private func validate(_ receipt: BrowserMCPConnectionReceipt) async throws {
        if let browserURL = receipt.browserURL {
            let endpoint = try await self.endpointResolver.resolve(browserURL)
            guard endpoint.webSocketDebuggerURL == receipt.webSocketDebuggerURL,
                  endpoint.browserID == receipt.devToolsBrowserID,
                  endpoint.browserVersion == receipt.browserVersion,
                  endpoint.protocolVersion == receipt.protocolVersion
            else {
                throw BrowserMCPConnectionError.connectionLost("the DevTools browser endpoint changed identity")
            }
        }
        if let processIdentifier = receipt.processIdentifier,
           let expectedGeneration = receipt.processStartIdentity
        {
            guard self.processStartIdentity(processIdentifier) == expectedGeneration else {
                throw BrowserMCPConnectionError.connectionLost(
                    "Chrome PID \(processIdentifier) changed process generation")
            }
        }
    }

    private func clearConnection() async {
        self.connectionReceipt = nil
        self.activeUploadID = nil
        let uploadWorkspace = self.uploadWorkspace
        self.uploadWorkspace = nil
        var shouldRemoveServer = self.manager.hasServer(name: self.serverName)
        if !shouldRemoveServer {
            shouldRemoveServer = await self.manager.isServerConnected(name: self.serverName)
        }
        if shouldRemoveServer {
            await self.manager.removeServer(name: self.serverName)
        }
        uploadWorkspace?.cleanup()
    }

    private func withExecutionGate<Result>(
        _ operation: @MainActor () async throws -> Result) async throws -> Result
    {
        try await self.executionGate.acquire()
        do {
            let result = try await operation()
            await self.executionGate.release()
            return result
        } catch {
            await self.executionGate.release()
            throw error
        }
    }
}
