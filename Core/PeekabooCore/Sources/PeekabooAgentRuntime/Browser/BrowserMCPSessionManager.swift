import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooFoundation
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

private struct BrowserMCPPreparedExecution {
    let receipt: BrowserMCPConnectionReceipt
    let connectionOutcome: DesktopActionOutcome?
}

extension TachikomaMCPClientManager: BrowserMCPManaging {
    func hasServer(name: String) -> Bool {
        self.getServerConfig(name: name) != nil
    }

    func serverToolCount(name: String) async -> Int {
        await self.getServerTools(name: name).count
    }
}

private enum BrowserMCPCallFailure: Error {
    case preDispatch(any Error)
    case mayHaveDispatched(any Error)
}

private struct BrowserMCPEnvironmentOptions: Sendable {
    let browserURL: String?
    let isolated: Bool
    let headless: Bool

    init(environment: [String: String]) {
        let browserURL = environment["PEEKABOO_BROWSER_MCP_BROWSER_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.browserURL = browserURL?.isEmpty == false ? browserURL : nil
        self.isolated = Self.flag("PEEKABOO_BROWSER_MCP_ISOLATED", in: environment)
        self.headless = Self.flag("PEEKABOO_BROWSER_MCP_HEADLESS", in: environment)
    }

    private static func flag(_ name: String, in environment: [String: String]) -> Bool {
        guard let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(value)
    }
}

private struct BrowserMCPResolvedTarget {
    let receipt: BrowserMCPConnectionReceipt
    let config: MCPServerConfig
    let supportsReceiptBoundExecution: Bool
}

private struct BrowserMCPStatusInspection {
    let status: BrowserMCPStatus
    let wasCancelled: Bool
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
    private let environmentOptions: BrowserMCPEnvironmentOptions
    private let executionGate = MCPToolSnapshotExecutionGate()
    private var connectionReceipt: BrowserMCPConnectionReceipt?
    private var connectionSupportsReceiptBoundExecution = false
    private var uploadWorkspace: BrowserMCPUploadWorkspace?
    private var activeUploadID: UUID?

    private static let connectionDelivery = DesktopActionOutcome.Delivery(
        mechanism: .browserProtocol,
        mode: .foreground)

    init(
        serverName: String,
        manager: any BrowserMCPManaging = TachikomaMCPClientManager(),
        detectedBrowsers: @escaping BrowserDetector = BrowserMCPService.detectRunningBrowsers,
        processStartIdentity: @escaping ProcessIdentityProvider = { processIdentifier in
            SystemIdentityResolver.processStartIdentity(processIdentifier)
        },
        endpointResolver: BrowserMCPDevToolsEndpointResolver = .live,
        uploadStager: BrowserMCPUploadStager = .live,
        environment: [String: String] = ProcessInfo.processInfo.environment)
    {
        self.serverName = serverName
        self.manager = manager
        self.detectedBrowsers = detectedBrowsers
        self.processStartIdentity = processStartIdentity
        self.endpointResolver = endpointResolver
        self.uploadStager = uploadStager
        self.environmentOptions = BrowserMCPEnvironmentOptions(environment: environment)
    }

    func status(channel: BrowserMCPChannel?) async -> BrowserMCPStatus {
        do {
            return try await self.withExecutionGate {
                await self.inspectStatusUnlocked(channel: channel).status
            }
        } catch {
            return BrowserMCPStatus(
                isConnected: false,
                toolCount: 0,
                detectedBrowsers: self.detectedBrowsers(channel),
                connectionReceipt: nil,
                error: error.localizedDescription)
        }
    }

    func statusForExecution(channel: BrowserMCPChannel?) async throws -> BrowserMCPStatus {
        let inspection = try await self.withExecutionGate {
            await self.inspectStatusUnlocked(channel: channel)
        }
        guard !inspection.wasCancelled else { throw CancellationError() }
        try Task.checkCancellation()
        return inspection.status
    }

    private func inspectStatusUnlocked(channel: BrowserMCPChannel?) async -> BrowserMCPStatusInspection {
        let browsers = self.detectedBrowsers(channel)
        guard let receipt = self.connectionReceipt else {
            if await self.manager.isServerConnected(name: self.serverName) || self.manager
                .hasServer(name: self.serverName)
            {
                await self.manager.removeServer(name: self.serverName)
            }
            return BrowserMCPStatusInspection(
                status: BrowserMCPStatus(
                    isConnected: false,
                    toolCount: 0,
                    detectedBrowsers: browsers,
                    connectionReceipt: nil),
                wasCancelled: false)
        }

        do {
            try await self.validate(receipt)
            guard await self.manager.isServerConnected(name: self.serverName) else {
                throw BrowserMCPConnectionError.connectionLost("the persistent MCP child is no longer connected")
            }
            return await BrowserMCPStatusInspection(
                status: BrowserMCPStatus(
                    isConnected: true,
                    toolCount: self.manager.serverToolCount(name: self.serverName),
                    detectedBrowsers: browsers,
                    connectionReceipt: receipt),
                wasCancelled: false)
        } catch is CancellationError {
            return BrowserMCPStatusInspection(
                status: BrowserMCPStatus(
                    isConnected: false,
                    toolCount: 0,
                    detectedBrowsers: browsers,
                    connectionReceipt: nil,
                    error: CancellationError().localizedDescription),
                wasCancelled: true)
        } catch {
            await self.clearConnection()
            return BrowserMCPStatusInspection(
                status: BrowserMCPStatus(
                    isConnected: false,
                    toolCount: 0,
                    detectedBrowsers: browsers,
                    connectionReceipt: nil,
                    error: error.localizedDescription),
                wasCancelled: false)
        }
    }

    func connect(channel: BrowserMCPChannel?, browserURL: String? = nil) async throws -> BrowserMCPStatus {
        try await self.connectWithOutcome(channel: channel, browserURL: browserURL).payload
    }

    func connectWithOutcome(
        channel: BrowserMCPChannel?,
        browserURL: String? = nil) async throws -> DesktopActionResult<BrowserMCPStatus>
    {
        try await self.withExecutionGate {
            try await self.connectUnlockedWithOutcome(channel: channel, browserURL: browserURL)
        }
    }

    private func connectUnlocked(
        channel: BrowserMCPChannel?,
        browserURL: String? = nil) async throws -> BrowserMCPStatus
    {
        try await self.connectUnlockedWithOutcome(channel: channel, browserURL: browserURL).payload
    }

    private func connectUnlockedWithOutcome(
        channel: BrowserMCPChannel?,
        browserURL: String? = nil) async throws -> DesktopActionResult<BrowserMCPStatus>
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
            let status = await self.inspectStatusUnlocked(channel: channel).status
            guard status.isConnected else {
                throw BrowserMCPConnectionError.connectionLost(
                    status.error ?? "the existing browser connection could not be verified")
            }
            return DesktopActionResult(payload: status, outcome: .confirmedNoChange())
        }

        if self.manager.hasServer(name: self.serverName) {
            await self.manager.removeServer(name: self.serverName)
        }
        var connectionAttemptDispatched = false
        do {
            let uploadWorkspace = try await self.uploadStager.createWorkspace()
            var config = target.config
            config.env["TMPDIR"] = uploadWorkspace.rootPath
            self.uploadWorkspace = uploadWorkspace
            connectionAttemptDispatched = true
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
            self.connectionSupportsReceiptBoundExecution = target.supportsReceiptBoundExecution
            let status = await self.inspectStatusUnlocked(channel: channel).status
            guard status.isConnected else {
                throw BrowserMCPConnectionError.connectionLost(
                    status.error ?? "the new browser connection could not be verified")
            }
            return DesktopActionResult(
                payload: status,
                outcome: .dispatchedUnverified(
                    delivery: Self.connectionDelivery,
                    evidence: .deliveryAccepted,
                    unitCount: .one))
        } catch let error as BrowserMCPUploadStagingError {
            await self.clearConnection()
            if connectionAttemptDispatched {
                throw Self.indeterminateConnectionFailure(error)
            }
            throw error
        } catch let error as BrowserMCPConnectionError {
            await self.clearConnection()
            if connectionAttemptDispatched {
                throw Self.indeterminateConnectionFailure(error)
            }
            throw error
        } catch {
            await self.clearConnection()
            if connectionAttemptDispatched {
                throw Self.indeterminateConnectionFailure(error)
            }
            throw BrowserMCPConnectionError.connectionProbeFailed(error.localizedDescription)
        }
    }

    private static func indeterminateConnectionFailure(_ cause: any Error) -> DesktopActionFailure {
        .indeterminate(
            delivery: self.connectionDelivery,
            evidence: .completionUnknown,
            unitCount: .one,
            message: "Browser connection completion is unknown after the provider accepted the request.",
            hint: "Check browser status before deciding whether to reconnect.",
            causeDescription: self.errorDescription(cause))
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
        let result = try await self.executeSequenceResult(calls, channel: channel)
        if result.providerReturnedError {
            return result.response
        }
        if let failure = result.actionFailure {
            throw failure
        }
        return result.response
    }

    func executeSequenceResult(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        connectionPolicy: BrowserMCPExecutionConnectionPolicy = .allowAutoConnect) async throws
        -> BrowserMCPExecutionResult
    {
        try await self.withExecutionGate {
            try await self.executeSequenceUnlocked(
                calls,
                channel: channel,
                expectedConnectionReceipt: nil,
                connectionPolicy: connectionPolicy)
        }
    }

    func executeSequence(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        expectedConnectionReceipt: BrowserMCPConnectionReceipt) async throws -> BrowserMCPExecutionResult
    {
        do {
            return try await self.withExecutionGate {
                try await self.executeSequenceUnlocked(
                    calls,
                    channel: channel,
                    expectedConnectionReceipt: expectedConnectionReceipt,
                    connectionPolicy: .requireExistingLiveReceipt)
            }
        } catch is CancellationError {
            throw Self.preDispatchFailure(CancellationError())
        }
    }

    /// This state machine keeps every post-dispatch boundary in one auditable control flow.
    private func executeSequenceUnlocked(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        expectedConnectionReceipt: BrowserMCPConnectionReceipt?,
        connectionPolicy: BrowserMCPExecutionConnectionPolicy) async throws -> BrowserMCPExecutionResult
    {
        guard !calls.isEmpty else {
            throw BrowserMCPConnectionError.connectionLost("the browser action sequence was empty")
        }
        let preparation = try await self.prepareExecutionReceipt(
            channel: channel,
            expectedConnectionReceipt: expectedConnectionReceipt,
            connectionPolicy: connectionPolicy)
        let receipt = preparation.receipt

        var completedCallCount = 0
        var dispatchedCallCount = 0
        var response: ToolResponse?
        var actionFailure: DesktopActionFailure?
        var failureStage: BrowserMCPExecutionFailureStage?
        var providerReturnedError = false
        var shouldValidateConnection = true
        for (index, call) in calls.enumerated() {
            let current: ToolResponse
            do {
                current = try await self.execute(call)
            } catch let failure as BrowserMCPCallFailure {
                failureStage = .call(index: index)
                switch failure {
                case let .preDispatch(cause):
                    guard completedCallCount > 0 else {
                        if preparation.connectionOutcome != nil {
                            actionFailure = Self.preDispatchFailure(cause)
                            response = .error(actionFailure?.message ?? "Browser sequence stopped")
                            break
                        }
                        if expectedConnectionReceipt != nil {
                            throw Self.preDispatchFailure(cause)
                        }
                        throw cause
                    }
                    actionFailure = Self.partialSequenceFailure(
                        completedCallCount: completedCallCount,
                        cause: cause)
                    response = .error(actionFailure?.message ?? "Browser sequence stopped")
                case let .mayHaveDispatched(cause):
                    dispatchedCallCount = completedCallCount + 1
                    actionFailure = Self.indeterminateSequenceFailure(
                        dispatchedCallCount: dispatchedCallCount,
                        completedCallCount: completedCallCount,
                        cause: cause)
                    response = .error(actionFailure?.message ?? "Browser sequence completion is unknown")
                    shouldValidateConnection = false
                    await self.clearConnection()
                }
                break
            } catch {
                failureStage = .call(index: index)
                dispatchedCallCount = completedCallCount + 1
                actionFailure = Self.indeterminateSequenceFailure(
                    dispatchedCallCount: dispatchedCallCount,
                    completedCallCount: completedCallCount,
                    cause: error)
                response = .error(actionFailure?.message ?? "Browser sequence completion is unknown")
                shouldValidateConnection = false
                await self.clearConnection()
                break
            }
            completedCallCount += 1
            dispatchedCallCount = completedCallCount
            response = current
            if current.isError {
                providerReturnedError = true
                failureStage = .call(index: index)
                actionFailure = Self.indeterminateSequenceFailure(
                    dispatchedCallCount: dispatchedCallCount,
                    completedCallCount: completedCallCount,
                    causeDescription: "The browser tool returned an error response.")
                break
            }
        }
        if shouldValidateConnection {
            do {
                try await self.validate(receipt)
                guard self.connectionReceipt == receipt else {
                    throw BrowserMCPConnectionError.connectionLost(
                        "the connection receipt changed before the browser response completed")
                }
            } catch {
                failureStage = .connectionValidation
                dispatchedCallCount = max(dispatchedCallCount, completedCallCount)
                actionFailure = Self.indeterminateSequenceFailure(
                    dispatchedCallCount: dispatchedCallCount,
                    completedCallCount: completedCallCount,
                    cause: error)
                response = .error(actionFailure?.message ?? "Browser connection completion is unknown")
                await self.clearConnection()
            }
        }
        guard let response,
              dispatchedCallCount > 0 || preparation.connectionOutcome?.dispatchState.mutationDispatched == true
        else {
            throw BrowserMCPConnectionError.connectionLost("the browser action sequence returned no response")
        }
        return BrowserMCPExecutionResult(
            response: response,
            connectionReceipt: receipt,
            connectionOutcome: preparation.connectionOutcome,
            completedCallCount: completedCallCount,
            dispatchedCallCount: dispatchedCallCount,
            actionFailure: actionFailure,
            failureStage: failureStage,
            providerReturnedError: providerReturnedError)
    }

    // Connection authority, target locking, and live-receipt validation stay in one pre-dispatch control flow.
    // swiftlint:disable:next cyclomatic_complexity
    private func prepareExecutionReceipt(
        channel: BrowserMCPChannel?,
        expectedConnectionReceipt: BrowserMCPConnectionReceipt?,
        connectionPolicy: BrowserMCPExecutionConnectionPolicy) async throws -> BrowserMCPPreparedExecution
    {
        if self.connectionReceipt == nil, expectedConnectionReceipt == nil {
            guard connectionPolicy == .allowAutoConnect else {
                throw Self.existingConnectionRequiredFailure()
            }
            let connection = try await self.connectUnlockedWithOutcome(
                channel: channel,
                browserURL: nil)
            guard connection.payload.isConnected,
                  let receipt = connection.payload.connectionReceipt,
                  self.connectionReceipt == receipt
            else {
                throw DesktopActionFailure.indeterminate(
                    delivery: connection.outcome?.delivery ?? Self.connectionDelivery,
                    evidence: .completionUnknown,
                    unitCount: connection.outcome?.dispatchState.unitCount ?? .one,
                    message: "Implicit browser connection lost its exact receipt before tool dispatch.",
                    hint: "Check browser status before deciding whether to reconnect.")
            }
            return BrowserMCPPreparedExecution(
                receipt: receipt,
                connectionOutcome: connection.outcome)
        }
        guard let receipt = self.connectionReceipt else {
            if expectedConnectionReceipt != nil {
                throw BrowserMCPConnectionError.expectedConnectionReceiptMismatch
            }
            if connectionPolicy == .requireExistingLiveReceipt {
                throw Self.existingConnectionRequiredFailure()
            }
            throw BrowserMCPConnectionError.connectionLost("no exact connection receipt exists")
        }
        if let expectedConnectionReceipt, receipt != expectedConnectionReceipt {
            throw BrowserMCPConnectionError.expectedConnectionReceiptMismatch
        }
        if expectedConnectionReceipt != nil, !self.connectionSupportsReceiptBoundExecution {
            throw BrowserMCPConnectionError.receiptBindingUnsupported
        }
        if let channel, channel != receipt.channel {
            if expectedConnectionReceipt != nil {
                throw BrowserMCPConnectionError.expectedConnectionReceiptMismatch
            }
            if connectionPolicy == .requireExistingLiveReceipt {
                throw Self.existingConnectionRequiredFailure(
                    cause: BrowserMCPConnectionError.targetLocked)
            }
            throw BrowserMCPConnectionError.targetLocked
        }
        do {
            try await self.validate(receipt)
        } catch let error as CancellationError {
            await self.clearConnection()
            if expectedConnectionReceipt != nil || connectionPolicy == .requireExistingLiveReceipt {
                throw Self.preDispatchFailure(error)
            }
            throw error
        } catch where expectedConnectionReceipt != nil {
            await self.clearConnection()
            throw BrowserMCPConnectionError.expectedConnectionReceiptMismatch
        } catch {
            await self.clearConnection()
            if connectionPolicy == .requireExistingLiveReceipt {
                throw Self.existingConnectionRequiredFailure(cause: error)
            }
            throw error
        }
        guard await self.manager.isServerConnected(name: self.serverName) else {
            await self.clearConnection()
            if expectedConnectionReceipt != nil {
                throw BrowserMCPConnectionError.expectedConnectionReceiptMismatch
            }
            let error = BrowserMCPConnectionError.connectionLost("the persistent MCP child exited")
            if connectionPolicy == .requireExistingLiveReceipt {
                throw Self.existingConnectionRequiredFailure(cause: error)
            }
            throw error
        }
        guard self.connectionReceipt == receipt else {
            let error = BrowserMCPConnectionError.connectionLost(
                "the connection receipt changed while checking the persistent MCP child")
            if expectedConnectionReceipt != nil {
                throw BrowserMCPConnectionError.expectedConnectionReceiptMismatch
            }
            if connectionPolicy == .requireExistingLiveReceipt {
                throw Self.existingConnectionRequiredFailure(cause: error)
            }
            throw error
        }
        return BrowserMCPPreparedExecution(
            receipt: receipt,
            connectionOutcome: nil)
    }

    private static func partialSequenceFailure(
        completedCallCount: Int,
        cause: any Error) -> DesktopActionFailure
    {
        self.partialSequenceFailure(
            completedCallCount: completedCallCount,
            causeDescription: self.errorDescription(cause))
    }

    static func preDispatchFailure(_ cause: any Error) -> DesktopActionFailure {
        if let failure = cause as? DesktopActionFailure {
            return failure
        }
        let reason: DesktopActionOutcome.RefusalReason
        let message: String
        let hint: String
        switch cause {
        case is CancellationError:
            reason = .requestCancelled
            message = "Browser execution was cancelled before tool dispatch."
            hint = "Submit a new request only if the browser action is still wanted."
        case is BrowserMCPUploadStagingError:
            reason = .invalidRequest
            message = "Browser upload validation failed before tool dispatch."
            hint = "Correct the upload source and retry the browser call."
        default:
            reason = .targetUnavailable
            message = "Browser execution was refused before tool dispatch."
            hint = "Refresh browser status and retry against its exact connection receipt."
        }
        return .preDispatchRefusal(
            reason: reason,
            message: message,
            hint: hint,
            causeDescription: self.errorDescription(cause))
    }

    private static func existingConnectionRequiredFailure(cause: (any Error)? = nil) -> DesktopActionFailure {
        .preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Browser execution requires an existing live exact connection receipt.",
            hint: "Connect the intended browser explicitly and retry.",
            causeDescription: cause.map(self.errorDescription))
    }

    private static func partialSequenceFailure(
        completedCallCount: Int,
        causeDescription: String) -> DesktopActionFailure
    {
        .partial(
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            unitCount: self.dispatchUnitCount(completedCallCount),
            message: "Browser execution stopped after \(completedCallCount) completed tool call(s).",
            hint: "Do not retry the whole sequence; observe the browser and resume only the unfinished suffix.",
            causeDescription: causeDescription)
    }

    private static func indeterminateSequenceFailure(
        dispatchedCallCount: Int,
        completedCallCount: Int? = nil,
        cause: any Error) -> DesktopActionFailure
    {
        self.indeterminateSequenceFailure(
            dispatchedCallCount: dispatchedCallCount,
            completedCallCount: completedCallCount,
            causeDescription: self.errorDescription(cause))
    }

    private static func indeterminateSequenceFailure(
        dispatchedCallCount: Int,
        completedCallCount: Int? = nil,
        causeDescription: String) -> DesktopActionFailure
    {
        let progress = completedCallCount.map {
            "\($0) completed, \(dispatchedCallCount) dispatched or accepted"
        } ?? "\(dispatchedCallCount) dispatched or accepted"
        return .indeterminate(
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .completionUnknown,
            unitCount: self.dispatchUnitCount(dispatchedCallCount),
            message: "Browser execution stopped with \(progress) tool call(s).",
            hint: "Do not retry the whole sequence; observe the browser before resuming unfinished work.",
            causeDescription: causeDescription)
    }

    private static func dispatchUnitCount(_ count: Int) -> DesktopActionOutcome.DispatchUnitCount {
        guard let unitCount = DesktopActionOutcome.DispatchUnitCount(count) else {
            preconditionFailure("A browser sequence failure must account for at least one dispatched call")
        }
        return unitCount
    }

    private static func errorDescription(_ error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func execute(_ call: BrowserMCPMappedCall) async throws -> ToolResponse {
        do {
            try Task.checkCancellation()
        } catch {
            throw BrowserMCPCallFailure.preDispatch(error)
        }
        guard call.toolName == "upload_file" else {
            do {
                return try await self.manager.executeTool(
                    serverName: self.serverName,
                    toolName: call.toolName,
                    arguments: call.arguments)
            } catch {
                throw BrowserMCPCallFailure.mayHaveDispatched(error)
            }
        }
        guard let sourcePath = call.arguments["filePath"] as? String, !sourcePath.isEmpty else {
            throw BrowserMCPCallFailure.preDispatch(
                BrowserMCPUploadStagingError.invalidPath(
                    "upload_file requires a non-empty filePath string"))
        }

        guard let uploadWorkspace = self.uploadWorkspace else {
            throw BrowserMCPCallFailure.preDispatch(
                BrowserMCPConnectionError.connectionLost("the browser upload workspace is unavailable"))
        }
        let stagedUpload: BrowserMCPStagedUpload
        do {
            stagedUpload = try await self.uploadStager.stage(path: sourcePath, in: uploadWorkspace)
            try Task.checkCancellation()
        } catch {
            throw BrowserMCPCallFailure.preDispatch(error)
        }
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
            throw BrowserMCPCallFailure.mayHaveDispatched(error)
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
        -> BrowserMCPResolvedTarget
    {
        if let browserURL = browserURL ?? self.environmentOptions.browserURL {
            return try await self.resolveExactEndpointTarget(browserURL: browserURL, channel: channel)
        }

        let resolvedChannel = channel ?? BrowserMCPService.preferredChannel()
        if self.environmentOptions.isolated {
            return BrowserMCPResolvedTarget(
                receipt: BrowserMCPConnectionReceipt(channel: resolvedChannel),
                config: BrowserMCPService.chromeDevToolsConfig(
                    target: .isolated(resolvedChannel),
                    headless: self.environmentOptions.headless),
                // The spawned process has no child-reported identity to bind into a signed receipt.
                supportsReceiptBoundExecution: false)
        }
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
        return BrowserMCPResolvedTarget(
            receipt: receipt,
            config: BrowserMCPService.chromeDevToolsConfig(
                target: .autoConnect(resolvedChannel),
                headless: self.environmentOptions.headless),
            // Ambient process inventory cannot prove which browser the MCP child attached to.
            supportsReceiptBoundExecution: false)
    }

    private func resolveExactEndpointTarget(
        browserURL: String,
        channel: BrowserMCPChannel?) async throws -> BrowserMCPResolvedTarget
    {
        let endpoint = try await self.endpointResolver.resolve(browserURL)
        let receipt = BrowserMCPConnectionReceipt(
            channel: channel,
            browserURL: endpoint.browserURL,
            webSocketDebuggerURL: endpoint.webSocketDebuggerURL,
            devToolsBrowserID: endpoint.browserID,
            browserVersion: endpoint.browserVersion,
            protocolVersion: endpoint.protocolVersion)
        return BrowserMCPResolvedTarget(
            receipt: receipt,
            config: BrowserMCPService.chromeDevToolsConfig(
                target: .exactWebSocket(endpoint.webSocketDebuggerURL),
                headless: self.environmentOptions.headless),
            supportsReceiptBoundExecution: true)
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
        self.connectionSupportsReceiptBoundExecution = false
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
