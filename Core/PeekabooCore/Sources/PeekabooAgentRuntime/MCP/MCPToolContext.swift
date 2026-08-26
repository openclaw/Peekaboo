import Foundation
import MCP
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

public struct MCPToolCapturePreflightRefusal: Sendable, Equatable {
    public let message: String
    public let hint: String?

    public init(message: String, hint: String? = nil) {
        self.message = message
        self.hint = hint
    }

    var diagnostic: String {
        self.hint.map { "\(self.message) Hint: \($0)" } ?? self.message
    }
}

/// Lightweight dependency container for MCP tools so they no longer reach for
/// global singletons directly. Each tool can receive the subset of
/// services it needs, which keeps tests deterministic and unlocks DI.
public struct MCPToolContext: @unchecked Sendable {
    public let executionHost: PeekabooServiceExecutionHost
    public let automation: any UIAutomationServiceProtocol
    public let menu: any MenuServiceProtocol
    public let windows: any WindowManagementServiceProtocol
    public let applications: any ApplicationServiceProtocol
    public let dialogs: any DialogServiceProtocol
    public let dock: any DockServiceProtocol
    public let screenCapture: any ScreenCaptureServiceProtocol
    public let desktopObservation: any DesktopObservationServiceProtocol
    public let snapshots: any SnapshotManagerProtocol
    public let screens: any ScreenServiceProtocol
    public let agent: (any AgentServiceProtocol)?
    public let permissions: PermissionsService
    public let permissionsStatusProvider: any PermissionsStatusProviding
    public let clipboard: any ClipboardServiceProtocol
    public let browser: any BrowserMCPClientProviding
    public let snapshotMutationCoordinator: (any MCPToolSnapshotMutationCoordinating)?
    public let snapshotExecutionGate: MCPToolSnapshotExecutionGate
    public let executionPolicy: MCPToolExecutionPolicy
    let capturePreflightRefusal: MCPToolCapturePreflightRefusal?
    let uiSnapshots: MCPToolUISnapshotStore

    @TaskLocal
    private static var taskOverride: MCPToolContext?
    @TaskLocal
    static var snapshotObservationStartedAt: Date?
    @MainActor
    private static var defaultContextFactory: (() -> MCPToolContext)?

    /// Default context backed by the configured factory closure.
    ///
    /// Task-local overrides can be read from any executor. Resolving the
    /// process-wide default synchronously requires the main thread; the guard
    /// provides an actionable diagnostic before `MainActor.assumeIsolated`
    /// verifies the executor. Off-main callers must use `sharedOnMainActor()`
    /// (an async actor hop) or pass an explicit `MCPToolContext`.
    /// This deliberately does **not** use `DispatchQueue.main.sync`, which can
    /// deadlock when the main actor is waiting on the calling task.
    public static var shared: MCPToolContext {
        if let override = self.taskOverride {
            return override
        }
        guard Thread.isMainThread else {
            fatalError(
                "MCPToolContext.shared must be accessed on the main thread. "
                    + "Use await MCPToolContext.sharedOnMainActor() or pass an explicit context.")
        }
        return MainActor.assumeIsolated {
            guard let factory = self.defaultContextFactory else {
                fatalError("MCPToolContext default factory not configured. Call configureDefaultContext(using:).")
            }
            return factory()
        }
    }

    /// Resolve `shared` from any isolation without a synchronous main-queue hop.
    @MainActor
    public static func sharedOnMainActor() -> MCPToolContext {
        self.shared
    }

    /// Temporarily override the shared context for the lifetime of `operation`.
    public static func withContext<T>(
        _ context: MCPToolContext,
        perform operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskOverride.withValue(context) {
            try await operation()
        }
    }

    /// Produce a fresh context using the process-wide services locator.
    ///
    /// Unconfigured factory is a programming error and traps. For recoverable
    /// construction (MCP server boot), use `makeDefaultIfConfigured()`.
    @MainActor
    public static func makeDefault() -> MCPToolContext {
        guard let factory = self.defaultContextFactory else {
            fatalError("MCPToolContext default factory not configured. Call configureDefaultContext(using:).")
        }
        return factory()
    }

    /// Recoverable default-context construction for callers that can fail open.
    ///
    /// Prefer this over `makeDefault()` at process/server startup so a missing
    /// factory becomes a thrown error instead of process termination.
    /// Does not change `ToolRegistry` or other programming-error invariants.
    @MainActor
    public static func makeDefaultIfConfigured() throws -> MCPToolContext {
        guard let factory = self.defaultContextFactory else {
            throw PeekabooError.operationError(
                message: "MCPToolContext default factory not configured. Call configureDefaultContext(using:).")
        }
        return factory()
    }

    /// Configure the default context factory used by `shared`/`makeDefault`.
    @MainActor
    public static func configureDefaultContext(using factory: @escaping () -> MCPToolContext) {
        self.defaultContextFactory = factory
    }

    /// Test helper that restores the exact process-wide factory after each case.
    @MainActor
    static func withDefaultContextFactoryForTesting<T>(
        _ factory: (() -> MCPToolContext)?,
        perform operation: @MainActor () async throws -> T) async rethrows -> T
    {
        let previousFactory = self.defaultContextFactory
        self.defaultContextFactory = factory
        defer { self.defaultContextFactory = previousFactory }
        return try await operation()
    }

    public init(
        automation: any UIAutomationServiceProtocol,
        menu: any MenuServiceProtocol,
        windows: any WindowManagementServiceProtocol,
        applications: any ApplicationServiceProtocol,
        dialogs: any DialogServiceProtocol,
        dock: any DockServiceProtocol,
        screenCapture: any ScreenCaptureServiceProtocol,
        desktopObservation: any DesktopObservationServiceProtocol,
        snapshots: any SnapshotManagerProtocol,
        screens: any ScreenServiceProtocol,
        agent: (any AgentServiceProtocol)?,
        permissions: PermissionsService,
        clipboard: any ClipboardServiceProtocol,
        browser: any BrowserMCPClientProviding,
        permissionsStatusProvider: (any PermissionsStatusProviding)? = nil,
        snapshotMutationCoordinator: (any MCPToolSnapshotMutationCoordinating)? = nil,
        snapshotExecutionGate: MCPToolSnapshotExecutionGate? = nil,
        snapshotOwner: MCPToolSnapshotOwner = .legacyProcess,
        executionPolicy: MCPToolExecutionPolicy = .backgroundOnly,
        executionHost: PeekabooServiceExecutionHost = .local,
        capturePreflightRefusal: MCPToolCapturePreflightRefusal? = nil)
    {
        self.executionHost = executionHost
        self.automation = automation
        self.menu = menu
        self.windows = windows
        self.applications = applications
        self.dialogs = dialogs
        self.dock = dock
        self.screenCapture = screenCapture
        self.desktopObservation = desktopObservation
        self.snapshots = snapshots
        self.screens = screens
        self.agent = agent
        self.permissions = permissions
        self.permissionsStatusProvider = permissionsStatusProvider ?? permissions
        self.clipboard = clipboard
        self.browser = browser
        self.snapshotMutationCoordinator = snapshotMutationCoordinator
        self.snapshotExecutionGate = snapshotExecutionGate
            ?? (agent as? PeekabooAgentService)?.snapshotExecutionGate
            ?? MCPToolSnapshotExecutionGate()
        self.uiSnapshots = MCPToolUISnapshotStore(owner: snapshotOwner)
        self.executionPolicy = executionPolicy
        self.capturePreflightRefusal = capturePreflightRefusal
    }

    @MainActor
    public init(
        services: any PeekabooServiceProviding,
        snapshotMutationCoordinator: (any MCPToolSnapshotMutationCoordinating)? = nil,
        snapshotExecutionGate: MCPToolSnapshotExecutionGate? = nil,
        snapshotOwner: MCPToolSnapshotOwner = .legacyProcess,
        executionPolicy: MCPToolExecutionPolicy = .backgroundOnly,
        capturePreflightRefusal: MCPToolCapturePreflightRefusal? = nil)
    {
        let resolvedSnapshotExecutionGate = snapshotExecutionGate
            ?? (services.agent as? PeekabooAgentService)?.snapshotExecutionGate
            ?? MCPToolSnapshotExecutionGate()
        self.init(
            automation: services.automation,
            menu: services.menu,
            windows: services.windows,
            applications: services.applications,
            dialogs: services.dialogs,
            dock: services.dock,
            screenCapture: services.screenCapture,
            desktopObservation: services.desktopObservation,
            snapshots: services.snapshots,
            screens: services.screens,
            agent: services.agent,
            permissions: services.permissions,
            clipboard: services.clipboard,
            browser: services.browser,
            permissionsStatusProvider: services,
            snapshotMutationCoordinator: snapshotMutationCoordinator,
            snapshotExecutionGate: resolvedSnapshotExecutionGate,
            snapshotOwner: snapshotOwner,
            executionPolicy: executionPolicy,
            executionHost: services.executionHost,
            capturePreflightRefusal: capturePreflightRefusal)
    }

    @MainActor
    public func execute(
        tool: any MCPTool,
        arguments: ToolArguments) async throws -> ToolResponse
    {
        let effect = MCPToolSnapshotMutationPolicy.effect(toolName: tool.name, arguments: arguments)
        if let rejection = MCPToolArgumentValidator.rejection(
            tool: tool,
            arguments: arguments,
            snapshotEffect: effect)
        {
            return rejection
        }
        if let rejection = self.executionPolicy.rejection(toolName: tool.name, arguments: arguments) {
            return rejection
        }
        if let capturePreflightResponse = self.capturePreflightResponse(tool: tool, arguments: arguments) {
            return capturePreflightResponse
        }
        await self.uiSnapshots.synchronizeImplicitLatestInvalidationWatermark(
            self.snapshots.effectiveImplicitLatestInvalidationWatermark)
        guard effect != .none else {
            return try await self.executeReadOnlyTool(tool, arguments: arguments)
        }

        try await self.snapshotExecutionGate.acquire()
        do {
            try Task.checkCancellation()
            if let pending = await self.snapshotExecutionGate.pendingInvalidation() {
                let retrySucceeded = await self.completeMutation(
                    pending.scope,
                    succeeded: false,
                    uiSnapshots: MCPToolUISnapshotStore(owner: pending.owner))
                try Task.checkCancellation()
                guard retrySucceeded else {
                    await self.snapshotExecutionGate.release()
                    return Self.pendingInvalidationResponse(
                        pendingScope: pending.scope,
                        blockedToolName: tool.name)
                }
                await self.snapshotExecutionGate.clearPendingInvalidation(id: pending.scope.id)
            }
        } catch {
            await self.snapshotExecutionGate.release()
            throw error
        }

        // Target authorization and leaf dispatch stay inside the same shared gate. Observation tools therefore cannot
        // replace either snapshot store between the identity check and the exact pinned tool invocation.
        let targetAuthorization: BackgroundTargetAuthorization
        let targetRevalidation: ToolResponse?
        do {
            targetAuthorization = try await self.backgroundTargetAuthorization(
                toolName: tool.name,
                arguments: arguments)
            targetRevalidation = try await self.backgroundTargetRevalidation(
                targetAuthorization,
                toolName: tool.name)
        } catch {
            await self.snapshotExecutionGate.release()
            throw error
        }
        if let rejection = targetAuthorization.rejection {
            await self.snapshotExecutionGate.release()
            return rejection
        }
        if let rejection = targetRevalidation {
            await self.snapshotExecutionGate.release()
            return rejection
        }
        if let rejection = self.backgroundMutationCapabilityRejection(
            toolName: tool.name,
            effect: effect)
        {
            await self.snapshotExecutionGate.release()
            return rejection
        }
        let executionArguments = targetAuthorization.arguments

        // All potentially suspending coordinator work completed before authorization. From this generation check to
        // entering the leaf there is no suspension; app/window/type/paste leaves then retain their own dispatch
        // receipt.

        let scope = MCPToolSnapshotMutationScope(
            toolName: tool.name,
            effect: effect,
            preservedSnapshotID: effect == .mutationProducingFreshObservation
                ? executionArguments.getString("snapshot")
                : nil)
        var toolStarted = false
        do {
            try Task.checkCancellation()
            try self.snapshotMutationCoordinator?.prepareMutation(scope)
            toolStarted = true
            var response = try await AuthorizedDesktopTargetPlan.$current.withValue(
                targetAuthorization.targetPlan)
            {
                try await Self.$snapshotObservationStartedAt.withValue(
                    effect == .mutationProducingFreshObservation ? scope.startedAt : nil)
                {
                    try await tool.execute(arguments: executionArguments)
                }
            }
            if Self.explicitlyNotDispatched(
                response,
                requiresCanonicalOutcome: self.executionPolicy == .backgroundOnly)
            {
                let cancelled = await self.snapshotMutationCoordinator?.cancelMutation(scope) ?? true
                await self.snapshotExecutionGate.release()
                guard cancelled else {
                    return ToolResponse.error(
                        "The tool was refused before dispatch, but its mutation reservation could not be cancelled",
                        meta: response.meta)
                }
                return response
            }
            response = Self.validatedBackgroundMutationResponse(
                response,
                toolName: tool.name,
                effect: effect,
                executionPolicy: self.executionPolicy)
            try Self.checkCancellationUnlessResponseIsCanonical(response)
            let completionCertificate = Self.mutationCompletionCertificate(response: response)
            let completedScope = scope.completed(
                at: Date(),
                preserving: response.isError ? nil : Self.refreshedSnapshotID(scope: scope, response: response),
                confirmedMutationCompletedAt: completionCertificate.completedAt,
                observationPreservationAllowed: completionCertificate.preservationAllowed)
            let completionSucceeded = await self.completeMutation(completedScope, succeeded: !response.isError)
            try Self.checkCancellationUnlessResponseIsCanonical(response)
            if !completionSucceeded {
                if !response.isError,
                   effect == .freshObservation || effect == .mutationProducingFreshObservation
                {
                    let rollbackSucceeded = await self.completeMutation(completedScope, succeeded: false)
                    try Self.checkCancellationUnlessResponseIsCanonical(response)
                    if !rollbackSucceeded {
                        await self.snapshotExecutionGate.recordPendingInvalidation(
                            completedScope,
                            owner: self.uiSnapshots.owner)
                    }
                    await self.snapshotExecutionGate.release()
                    return ToolResponse.error("Failed to publish the refreshed UI snapshot")
                }

                await self.snapshotExecutionGate.recordPendingInvalidation(
                    completedScope,
                    owner: self.uiSnapshots.owner)
                if response.isError {
                    await self.snapshotExecutionGate.release()
                    return response
                }

                await self.snapshotExecutionGate.release()
                return Self.mutationCompletionWarningResponse(
                    response,
                    toolName: tool.name)
            }
            await self.snapshotExecutionGate.release()
            return response
        } catch {
            if toolStarted {
                let failedScope = scope.completed(at: Date(), preserving: nil)
                let cleanupSucceeded = await self.completeMutation(failedScope, succeeded: false)
                if !cleanupSucceeded {
                    await self.snapshotExecutionGate.recordPendingInvalidation(
                        failedScope,
                        owner: self.uiSnapshots.owner)
                }
            }
            await self.snapshotExecutionGate.release()
            throw error
        }
    }

    private func executeReadOnlyTool(
        _ tool: any MCPTool,
        arguments: ToolArguments) async throws -> ToolResponse
    {
        let authorization: BackgroundTargetAuthorization
        if self.executionPolicy == .backgroundOnly,
           MCPToolRequestSemantics.isSafeBackgroundApplicationLaunchNoOp(arguments)
        {
            authorization = try await self.backgroundTargetAuthorization(
                toolName: tool.name,
                arguments: arguments)
            if let rejection = authorization.rejection {
                return rejection
            }
            if let rejection = try await self.backgroundTargetRevalidation(
                authorization,
                toolName: tool.name)
            {
                return rejection
            }
        } else {
            authorization = BackgroundTargetAuthorization(
                arguments: arguments,
                rejection: nil,
                targetPlan: nil)
        }

        try Task.checkCancellation()
        let response = try await AuthorizedDesktopTargetPlan.$current.withValue(authorization.targetPlan) {
            try await tool.execute(arguments: authorization.arguments)
        }
        try Task.checkCancellation()
        return response
    }

    private func capturePreflightResponse(
        tool: any MCPTool,
        arguments: ToolArguments) -> ToolResponse?
    {
        guard let capturePreflightRefusal else { return nil }
        guard let requiresOwnerPreflight = MCPToolCaptureRequirement.requiresScreenCaptureKitOwnerPreflight(
            toolName: tool.name,
            arguments: arguments)
        else {
            return MCPToolResponseMetadataProjector.preDispatchRefusalResponse(
                message: "Tool '\(tool.name)' has no capture-safety classification and is refused while " +
                    "ScreenCaptureKit ownership is unavailable.",
                reason: .runtimeIncompatible,
                additionalFields: ["error_code": .string("CAPTURE_POLICY_UNCLASSIFIED")])
        }
        guard requiresOwnerPreflight else { return nil }
        return MCPToolResponseMetadataProjector.preDispatchRefusalResponse(
            message: capturePreflightRefusal.diagnostic,
            reason: .runtimeIncompatible,
            additionalFields: [
                "error_code": .string("CAPTURE_FAILED"),
                "hint": capturePreflightRefusal.hint.map(Value.string) ?? .null,
            ])
    }

    func releaseSnapshotOwner() async {
        await self.uiSnapshots.removeOwner()
    }

    func replacingSnapshotOwner(with owner: MCPToolSnapshotOwner) -> Self {
        Self(
            automation: self.automation,
            menu: self.menu,
            windows: self.windows,
            applications: self.applications,
            dialogs: self.dialogs,
            dock: self.dock,
            screenCapture: self.screenCapture,
            desktopObservation: self.desktopObservation,
            snapshots: self.snapshots,
            screens: self.screens,
            agent: self.agent,
            permissions: self.permissions,
            clipboard: self.clipboard,
            browser: self.browser,
            permissionsStatusProvider: self.permissionsStatusProvider,
            snapshotMutationCoordinator: self.snapshotMutationCoordinator,
            snapshotExecutionGate: self.snapshotExecutionGate,
            snapshotOwner: owner,
            executionPolicy: self.executionPolicy,
            executionHost: self.executionHost,
            capturePreflightRefusal: self.capturePreflightRefusal)
    }

    struct BackgroundTargetAuthorization {
        let arguments: ToolArguments
        let rejection: ToolResponse?
        let targetPlan: AuthorizedDesktopTargetPlan?
    }

    private func backgroundTargetAuthorization(
        toolName: String,
        arguments: ToolArguments) async throws -> BackgroundTargetAuthorization
    {
        func permitted(_ arguments: ToolArguments) -> BackgroundTargetAuthorization {
            BackgroundTargetAuthorization(arguments: arguments, rejection: nil, targetPlan: nil)
        }
        func refused(_ response: ToolResponse?) -> BackgroundTargetAuthorization {
            BackgroundTargetAuthorization(arguments: arguments, rejection: response, targetPlan: nil)
        }

        guard self.executionPolicy == .backgroundOnly else { return permitted(arguments) }
        let usesSnapshotTarget = ["action", "click", "scroll", "set_value"].contains(toolName) ||
            (["type", "press"].contains(toolName) &&
                (arguments.getValue(for: "on") != nil || arguments.getValue(for: "snapshot") != nil))
        guard usesSnapshotTarget else {
            // BrowserTool mutates DevTools page targets rather than macOS desktop targets. Its policy separately
            // requires background pages and forbids page fronting before dispatch.
            if ["type", "press"].contains(toolName) {
                return BackgroundTargetAuthorization(
                    arguments: arguments,
                    rejection: self.executionPolicy.unresolvedTargetRejection(
                        toolName: toolName,
                        detail: "background Agent keyboard input requires an exact non-dialog snapshot " +
                            "or element target"),
                    targetPlan: nil)
            }
            return await self.backgroundApplicationTargetAuthorization(
                toolName: toolName,
                arguments: arguments)
        }
        if ["type", "press"].contains(toolName),
           ["app", "pid", "window_id", "window_title", "window_index"].contains(where: {
               arguments.getValue(for: $0) != nil
           })
        {
            return BackgroundTargetAuthorization(
                arguments: arguments,
                rejection: self.executionPolicy.unresolvedTargetRejection(
                    toolName: toolName,
                    detail: "snapshot keyboard input cannot include competing app, PID, or window selectors"),
                targetPlan: nil)
        }
        let snapshotSelector = Self.strictString(arguments, key: "snapshot")
        let coordinateSelector = Self.strictString(arguments, key: "coordinate_reference")
        if snapshotSelector.isInvalid {
            return refused(self.executionPolicy.unresolvedTargetRejection(
                toolName: toolName,
                detail: "snapshot must be a nonempty string containing an exact observation ID"))
        }
        if coordinateSelector.isInvalid {
            return refused(self.executionPolicy.unresolvedTargetRejection(
                toolName: toolName,
                detail: "coordinate_reference must be a nonempty string containing an exact observation ID"))
        }
        let snapshotID = snapshotSelector.value
        let coordinateReference = coordinateSelector.value
        if let snapshotID, let coordinateReference, snapshotID != coordinateReference {
            return refused(self.executionPolicy.unresolvedTargetRejection(
                toolName: toolName,
                detail: "snapshot and coordinate_reference identify different targets"))
        }
        let requestedSnapshotID = snapshotID ?? coordinateReference
        // ClickTool intentionally accepts either selector as the same capture-owned coordinate receipt. Its leaf
        // revalidates the exact PID/window/generation/bounds and rejects points outside that captured window.
        if toolName == "click", arguments.getValue(for: "coords") != nil, requestedSnapshotID == nil {
            return refused(self.executionPolicy.unresolvedTargetRejection(
                toolName: toolName,
                detail: "background coordinates require an explicit exact snapshot or coordinate_reference"))
        }
        let mirroredSnapshot = await self.uiSnapshots.getSnapshot(id: requestedSnapshotID)
        let effectiveSnapshotID = requestedSnapshotID ?? mirroredSnapshot?.id
        guard let effectiveSnapshotID else {
            return refused(self.executionPolicy.unresolvedTargetRejection(
                toolName: toolName,
                detail: "no current snapshot identifies the target"))
        }
        let detectionResult: ElementDetectionResult
        do {
            guard let result = try await self.snapshots.getDetectionResult(snapshotId: effectiveSnapshotID),
                  result.snapshotId == effectiveSnapshotID
            else {
                throw DesktopTargetIdentityError.snapshotSourceMismatch
            }
            detectionResult = result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return refused(self.executionPolicy.unresolvedTargetRejection(
                toolName: toolName,
                detail: "snapshot '\(effectiveSnapshotID)' has no authoritative application identity"))
        }
        guard let windowContext = detectionResult.metadata.windowContext else {
            return refused(self.executionPolicy.unresolvedTargetRejection(
                toolName: toolName,
                detail: "snapshot '\(effectiveSnapshotID)' has no authoritative application identity"))
        }
        guard !detectionResult.metadata.isDialog else {
            return refused(self.executionPolicy.unresolvedTargetRejection(
                toolName: toolName,
                detail: "dialog mutation is unavailable until an exact dialog ownership receipt is preserved"))
        }
        let applicationBundleIdentifier = Self.nonEmpty(windowContext.applicationBundleId)
        let applicationName = Self.nonEmpty(windowContext.applicationName)
        guard applicationBundleIdentifier != nil || applicationName != nil else {
            return refused(self.executionPolicy.unresolvedTargetRejection(
                toolName: toolName,
                detail: "snapshot '\(effectiveSnapshotID)' has no authoritative application name or bundle ID"))
        }
        if let rejection = self.executionPolicy.systemSurfaceRejection(
            toolName: toolName,
            applicationBundleIdentifier: applicationBundleIdentifier,
            applicationName: applicationName)
        {
            return refused(rejection)
        }
        guard let mirroredSnapshot, mirroredSnapshot.id == effectiveSnapshotID else {
            return refused(self.executionPolicy.unresolvedTargetRejection(
                toolName: toolName,
                detail: "snapshot '\(effectiveSnapshotID)' is absent from the tool snapshot store"))
        }
        let targetPlan: AuthorizedDesktopTargetPlan
        do {
            targetPlan = try await self.backgroundSnapshotTargetPlan(
                toolName: toolName,
                snapshotID: effectiveSnapshotID,
                mirroredSnapshot: mirroredSnapshot,
                detectionResult: detectionResult)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return refused(self.executionPolicy.unresolvedTargetRejection(
                toolName: toolName,
                detail: "the tool and automation snapshots disagree about target ownership"))
        }
        // The in-process implicit latest is session-owned. The authoritative store may be shared by
        // multiple local or Bridge clients, so its process-wide latest pointer is not evidence about
        // this session. Exact detection and target receipts above remain the fail-closed authority.
        var pinnedArguments = arguments.rawDictionary
        pinnedArguments["snapshot"] = effectiveSnapshotID
        if coordinateReference != nil {
            pinnedArguments["coordinate_reference"] = effectiveSnapshotID
        }
        return BackgroundTargetAuthorization(
            arguments: ToolArguments(raw: pinnedArguments),
            rejection: nil,
            targetPlan: targetPlan)
    }

    private func backgroundApplicationTargetAuthorization(
        toolName: String,
        arguments: ToolArguments) async -> BackgroundTargetAuthorization
    {
        guard let schema = Self.backgroundApplicationTargetSchema(toolName: toolName) else {
            return BackgroundTargetAuthorization(arguments: arguments, rejection: nil, targetPlan: nil)
        }

        do {
            if let authorization = try await self.backgroundExactWindowTargetAuthorization(
                toolName: toolName,
                arguments: arguments)
            {
                return authorization
            }
            var identifiers = try Self.applicationIdentifiers(arguments: arguments, schema: schema)
            let windowTargetIdentities = try await self.windowTargetIdentities(
                arguments: arguments,
                keys: schema.windowIDKeys)
            let windowProcessIdentities = windowTargetIdentities.map(\.processIdentity)
            identifiers.append(contentsOf: windowProcessIdentities.map { "PID:\($0.processIdentifier)" })
            guard !identifiers.isEmpty else {
                throw BackgroundTargetResolutionError(
                    "the mutation has no explicit application or exact-window owner")
            }
            let authorities = try await self.resolveApplicationAuthorities(identifiers)
            let applications = authorities.map(\.authority.application.application)
            let processIdentity = try Self.validatedProcessIdentity(
                applications: applications,
                windowProcessIdentities: windowProcessIdentities)
            for application in applications {
                if let rejection = self.executionPolicy.systemSurfaceRejection(
                    toolName: toolName,
                    applicationBundleIdentifier: application.bundleIdentifier,
                    applicationName: application.name)
                {
                    return BackgroundTargetAuthorization(
                        arguments: arguments,
                        rejection: rejection,
                        targetPlan: nil)
                }
            }
            let processTarget = try DesktopTargetIdentity(processIdentity: processIdentity)
            let authorizedTarget = try windowTargetIdentities.reduce(processTarget) { partial, windowTarget in
                try partial.coalescing(windowTarget)
            }
            let targetPlan: AuthorizedDesktopTargetPlan
            if windowTargetIdentities.isEmpty, let authority = authorities.first {
                targetPlan = AuthorizedDesktopTargetPlan(mutationAuthority: authority)
            } else {
                let authority = try await self.receiptBoundMutationAuthority(for: authorizedTarget)
                targetPlan = AuthorizedDesktopTargetPlan(mutationAuthority: authority)
            }
            return BackgroundTargetAuthorization(
                arguments: Self.argumentsPinnedToProcess(
                    arguments,
                    toolName: toolName,
                    processIdentifier: processIdentity.processIdentifier),
                rejection: nil,
                targetPlan: targetPlan)
        } catch let error as BackgroundTargetResolutionError {
            let detail = if toolName == "app",
                            arguments.getString("action")?.lowercased() == "launch"
            {
                "background launch is limited to an exact already-running application readiness check; " +
                    "cold launch requires explicit foreground consent: \(error.detail)"
            } else {
                error.detail
            }
            return BackgroundTargetAuthorization(
                arguments: arguments,
                rejection: self.executionPolicy.unresolvedTargetRejection(
                    toolName: toolName,
                    detail: detail),
                targetPlan: nil)
        } catch {
            return BackgroundTargetAuthorization(
                arguments: arguments,
                rejection: self.executionPolicy.unresolvedTargetRejection(
                    toolName: toolName,
                    detail: "the selected target owner could not be validated before dispatch"),
                targetPlan: nil)
        }
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    struct StrictStringSelector {
        let isInvalid: Bool
        let value: String?
    }

    static func strictString(_ arguments: ToolArguments, key: String) -> StrictStringSelector {
        guard let raw = arguments.getValue(for: key) else {
            return StrictStringSelector(isInvalid: false, value: nil)
        }
        guard case let .string(value) = raw, let value = Self.nonEmpty(value) else {
            return StrictStringSelector(isInvalid: true, value: nil)
        }
        return StrictStringSelector(isInvalid: false, value: value)
    }

    @MainActor
    private func completeMutation(
        _ scope: MCPToolSnapshotMutationScope,
        succeeded: Bool,
        uiSnapshots: MCPToolUISnapshotStore? = nil) async -> Bool
    {
        guard scope.effect != .freshObservation else { return true }
        let resolvedScope: MCPToolSnapshotMutationScope
        do {
            if let barrier = try self.snapshotMutationCoordinator?.completeMutationBarrier(scope) {
                resolvedScope = scope.completed(
                    at: scope.completedAt ?? Date(),
                    preserving: scope.preservedSnapshotID,
                    confirmedMutationCompletedAt: max(
                        scope.confirmedMutationCompletedAt ?? barrier.cutoff,
                        barrier.cutoff),
                    observationPreservationAllowed: (scope.observationPreservationAllowed ?? true) &&
                        barrier.allowsObservationPreservation)
            } else {
                resolvedScope = scope
            }
        } catch {
            return false
        }
        let sharedWatermark = self.snapshots.effectiveImplicitLatestInvalidationWatermark
        let wantsPreservation = succeeded &&
            resolvedScope.effect == .mutationProducingFreshObservation &&
            resolvedScope.preservedSnapshotID != nil
        let preservationBoundary = resolvedScope.confirmedMutationCompletedAt ?? resolvedScope.startedAt
        let preservationAllowed = !wantsPreservation ||
            ((resolvedScope.observationPreservationAllowed ?? true) &&
                (sharedWatermark.map { $0 <= preservationBoundary } ?? true))
        let effectiveSucceeded = succeeded && preservationAllowed
        let requestedCutoff = resolvedScope.invalidationCutoff(succeeded: effectiveSucceeded)
        let cutoff = max(
            requestedCutoff,
            sharedWatermark ?? requestedCutoff)
        let preservedSnapshotID = effectiveSucceeded ? resolvedScope.preservedSnapshotID : nil
        await (uiSnapshots ?? self.uiSnapshots).invalidateImplicitLatestSnapshot(
            through: cutoff,
            preserving: preservedSnapshotID,
            preservedAt: preservedSnapshotID == nil ? nil : resolvedScope.completedAt)

        let coordinatorScope = effectiveSucceeded ? resolvedScope : MCPToolSnapshotMutationScope(
            id: resolvedScope.id,
            toolName: resolvedScope.toolName,
            startedAt: resolvedScope.startedAt,
            effect: resolvedScope.effect,
            preservedSnapshotID: nil,
            completedAt: resolvedScope.completedAt,
            confirmedMutationCompletedAt: resolvedScope.confirmedMutationCompletedAt,
            observationPreservationAllowed: resolvedScope.observationPreservationAllowed)
        if let snapshotMutationCoordinator {
            let completed = await snapshotMutationCoordinator.completeMutation(
                coordinatorScope,
                succeeded: effectiveSucceeded)
            return completed && preservationAllowed
        }

        do {
            _ = try await self.snapshots.invalidateImplicitLatestSnapshot(
                through: cutoff,
                preserving: preservedSnapshotID,
                preservedAt: preservedSnapshotID == nil ? nil : resolvedScope.completedAt)
            return preservationAllowed
        } catch {
            return false
        }
    }

    private static func mutationCompletionCertificate(
        response: ToolResponse) -> (completedAt: Date?, preservationAllowed: Bool?)
    {
        guard case let .object(meta)? = response.meta else { return (nil, nil) }
        let completedAt: Date? = if case let .double(seconds)? = meta["desktop_mutation_completed_at"] {
            Date(timeIntervalSinceReferenceDate: seconds)
        } else {
            nil
        }
        let preservationAllowed: Bool? = if case let .bool(allowed)? =
            meta["desktop_mutation_preservation_allowed"]
        {
            allowed
        } else {
            nil
        }
        return (completedAt, preservationAllowed)
    }

    private static func explicitlyNotDispatched(
        _ response: ToolResponse,
        requiresCanonicalOutcome: Bool) -> Bool
    {
        guard case let .object(meta)? = response.meta,
              case .bool(false)? = meta["mutation_dispatched"]
        else { return false }
        if requiresCanonicalOutcome {
            guard case let .valid(projection) =
                MCPToolResponseMetadataProjector.actionOutcomeResolution(from: response.meta)
            else { return false }
            return projection.dispatchState == .none
        }
        return true
    }

    private static func checkCancellationUnlessResponseIsCanonical(_ response: ToolResponse) throws {
        guard Task.isCancelled else { return }
        if case .valid = MCPToolResponseMetadataProjector.actionOutcomeResolution(from: response.meta) {
            return
        }
        throw CancellationError()
    }

    private static func validatedBackgroundMutationResponse(
        _ response: ToolResponse,
        toolName: String,
        effect: MCPToolSnapshotEffect,
        executionPolicy: MCPToolExecutionPolicy) -> ToolResponse
    {
        guard executionPolicy == .backgroundOnly,
              effect == .conditionalMutation || effect == .mutation ||
              effect == .mutationProducingFreshObservation
        else { return response }

        switch MCPToolResponseMetadataProjector.actionOutcomeResolution(from: response.meta) {
        case let .valid(projection):
            if projection.outcome.isAccepted(by: .confirmedOrDispatched),
               let delivery = projection.outcome.delivery,
               delivery.mode != .background
            {
                let downgraded = DesktopActionOutcome.dispatchedUnverified(
                    route: projection.outcome.route,
                    delivery: delivery,
                    evidence: projection.outcome.evidence == .operationStillRunning
                        ? .operationStillRunning
                        : .deliveryAccepted,
                    unitCount: projection.outcome.dispatchState.unitCount)
                let externalFields = MCPToolResponseMetadataProjector.externalFields(
                    from: response.meta,
                    toolName: toolName)
                return ToolResponse.error(
                    "The \(toolName) mutation violated background-only authority by reporting foreground delivery.",
                    meta: try? MCPToolResponseMetadataProjector.metadata(
                        merging: externalFields,
                        outcome: downgraded))
            }
            guard !projection.outcome.isAccepted(by: .confirmedOrDispatched) else { return response }
            guard !response.isError else { return response }
            return ToolResponse.error(
                "The \(toolName) mutation returned a non-success canonical outcome.",
                meta: response.meta)
        case .absent, .invalid:
            let failure = DesktopActionFailure.indeterminate(
                evidence: .completionUnknown,
                message: "The \(toolName) mutation returned without valid canonical result semantics.",
                hint: "Observe the intended target before retrying and update the runtime host.")
            var additionalFields = MCPToolResponseMetadataProjector.externalFields(
                from: response.meta,
                toolName: toolName)
            for key in MCPToolResponseMetadataProjector.actionOutcomeKeys {
                additionalFields.removeValue(forKey: key)
            }
            return (try? MCPToolResponseMetadataProjector.errorResponse(
                for: failure,
                invalidatedSnapshotID: nil,
                additionalFields: additionalFields)) ?? ToolResponse.error(failure.message)
        }
    }

    func backgroundMutationCapabilityRejection(
        toolName: String,
        effect: MCPToolSnapshotEffect) -> ToolResponse?
    {
        guard self.executionPolicy == .backgroundOnly,
              effect == .conditionalMutation || effect == .mutation ||
              effect == .mutationProducingFreshObservation
        else { return nil }

        let supported: Bool? = switch toolName {
        case "click", "type", "set_value", "action", "scroll", "press", "paste":
            self.automation is any UIAutomationActionOutcomeProviding
        case "see", "inspect_ui":
            self.automation is any UIAutomationObservationActionResultProviding
        default:
            nil
        }
        guard supported == false else { return nil }
        return MCPToolResponseMetadataProjector.preDispatchRefusalResponse(
            message: "The selected runtime cannot provide canonical result semantics for background \(toolName).",
            reason: .runtimeIncompatible,
            additionalFields: [
                "execution_policy": .string(self.executionPolicy.rawValue),
            ])
    }

    private static func refreshedSnapshotID(
        scope: MCPToolSnapshotMutationScope,
        response: ToolResponse) -> String?
    {
        guard scope.effect == .mutationProducingFreshObservation,
              case let .object(meta)? = response.meta,
              case let .string(actualSnapshotID)? = meta["snapshot_id"],
              !actualSnapshotID.isEmpty
        else { return nil }
        return actualSnapshotID
    }

    private static func mutationCompletionWarningResponse(
        _ response: ToolResponse,
        toolName: String) -> ToolResponse
    {
        let warning = "Warning: The \(toolName) mutation completed, but UI snapshot cleanup is pending. " +
            "Do not retry this mutation; cleanup will be retried before the next snapshot-sensitive tool."
        var content = response.content
        if case let .text(text, annotations, meta)? = content.first {
            content[0] = .text(text: "\(text)\n\n\(warning)", annotations: annotations, _meta: meta)
        } else {
            content.insert(.text(text: warning, annotations: nil, _meta: nil), at: 0)
        }
        return ToolResponse(
            content: content,
            isError: false,
            meta: self.snapshotInvalidationMetadata(
                existing: response.meta,
                status: "pending_retry",
                warning: warning,
                toolExecuted: true,
                retryTool: false))
    }

    private static func pendingInvalidationResponse(
        pendingScope: MCPToolSnapshotMutationScope,
        blockedToolName: String) -> ToolResponse
    {
        let warning = "UI snapshot cleanup remains pending after the \(pendingScope.toolName) mutation. " +
            "The \(blockedToolName) tool was not executed; retry this request later."
        return ToolResponse.error(
            warning,
            meta: self.snapshotInvalidationMetadata(
                existing: nil,
                status: "pending_retry",
                warning: warning,
                toolExecuted: false,
                retryTool: true))
    }

    private static func snapshotInvalidationMetadata(
        existing: Value?,
        status: String,
        warning: String,
        toolExecuted: Bool,
        retryTool: Bool) -> Value
    {
        var metadata: [String: Value] = switch existing {
        case let .object(values)?:
            values
        case let existing?:
            ["tool_meta": existing]
        case nil:
            [:]
        }
        metadata["snapshot_invalidation"] = .object([
            "status": .string(status),
            "warning": .string(warning),
            "tool_executed": .bool(toolExecuted),
            "retry_tool": .bool(retryTool),
        ])
        return .object(metadata)
    }
}
