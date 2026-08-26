import CoreGraphics
import Foundation
import TachikomaMCP

struct BrowserNativeWindowBindingProof: Sendable, Equatable {
    enum Quality: String, Sendable, Equatable {
        case exact
    }

    let pageReference: String
    let nativeWindowReceipt: BrowserNativeWindowReceipt
    let quality: Quality
}

enum BrowserNativeWindowBindingCoordinatorError: Error, Equatable {
    case invalidPageCapability
    case invalidNativeWindow
    case privateTargetUnavailable
    case controlUnavailable
    case correlationRefused
    case deadlineExceeded
}

enum BrowserNativeWindowBindingCoordinator {
    struct Dependencies: Sendable {
        let receiptProviders: BrowserNativeWindowReceiptResolver.Providers

        static let live = Self(receiptProviders: .live)
    }

    struct Context: Sendable {
        let sessionBinding: BrowserMCPExecutionSessionBinding
        let capabilities: BrowserToolCapabilitySession
        let manager: BrowserMCPSessionManager
        let deadline: ContinuousClock.Instant
    }

    private struct BindAuthorityRequest: Sendable {
        let pageReference: String
        let nativeTarget: BrowserNativeWindowTarget
        let privateTargetID: String
        let context: Context
        let receiptProviders: BrowserNativeWindowReceiptResolver.Providers
    }

    @MainActor
    static func bind(
        pageReference: String,
        nativeTarget: BrowserNativeWindowTarget,
        context: Context,
        dependencies: Dependencies) async throws -> BrowserNativeWindowBindingProof
    {
        try await context.capabilities.withExclusiveOperation {
            let resolved: BrowserToolCapabilitySession.ResolvedArguments
            do {
                resolved = try await context.capabilities.resolve(
                    action: .snapshot,
                    arguments: ToolArguments(raw: ["page_id": pageReference]),
                    sessionBinding: context.sessionBinding)
            } catch {
                throw BrowserNativeWindowBindingCoordinatorError.invalidPageCapability
            }
            guard let providerPageID = resolved.providerPageID else {
                throw BrowserNativeWindowBindingCoordinatorError.invalidPageCapability
            }

            do {
                return try await context.manager.withPrivateTargetBindingAuthority(
                    providerPageID: providerPageID,
                    expectedSessionBinding: context.sessionBinding,
                    deadline: context.deadline)
                { control, privateTargetID in
                    do {
                        return try await self.bindUnderAuthority(
                            .init(
                                pageReference: pageReference,
                                nativeTarget: nativeTarget,
                                privateTargetID: privateTargetID,
                                context: context,
                                receiptProviders: dependencies.receiptProviders),
                            control: control)
                    } catch {
                        throw await self.validationError(
                            error,
                            pageReference: pageReference,
                            capabilities: context.capabilities,
                            control: control,
                            deadline: context.deadline)
                    }
                }
            } catch is CancellationError {
                await self.invalidateAfterPrivateLookupFailure(
                    pageReference: pageReference,
                    context: context)
                throw CancellationError()
            } catch BrowserMCPPrivateInteropError.authorityUnavailable {
                await context.capabilities.invalidateNativeWindowBindings()
                throw BrowserNativeWindowBindingCoordinatorError.controlUnavailable
            } catch BrowserMCPPrivateInteropError.deadlineExceeded {
                await self.invalidateAfterPrivateLookupFailure(
                    pageReference: pageReference,
                    context: context)
                throw BrowserNativeWindowBindingCoordinatorError.deadlineExceeded
            } catch is BrowserMCPPrivateInteropError {
                await self.invalidateAfterPrivateLookupFailure(
                    pageReference: pageReference,
                    context: context)
                throw BrowserNativeWindowBindingCoordinatorError.privateTargetUnavailable
            } catch let error as BrowserNativeWindowBindingCoordinatorError {
                throw error
            } catch {
                await self.invalidateAfterPrivateLookupFailure(
                    pageReference: pageReference,
                    context: context)
                throw BrowserNativeWindowBindingCoordinatorError.privateTargetUnavailable
            }
        }
    }

    @MainActor
    static func withRevalidatedMutation<Result: Sendable>(
        pageReference: String,
        context: Context,
        receiptProviders: BrowserNativeWindowReceiptResolver.Providers,
        mutation: @MainActor @Sendable (BrowserNativeWindowReceipt) async throws -> Result) async throws -> Result
    {
        try await context.capabilities.withExclusiveOperation {
            do {
                return try await context.manager.withNativeBindingExecutionGate(
                    expectedSessionBinding: context.sessionBinding)
                { control in
                    let revalidatedReceipt: BrowserNativeWindowReceipt
                    do {
                        revalidatedReceipt = try await self.revalidateUnderAuthority(
                            pageReference: pageReference,
                            context: context,
                            control: control,
                            receiptProviders: receiptProviders)
                    } catch {
                        throw await self.validationError(
                            error,
                            pageReference: pageReference,
                            capabilities: context.capabilities,
                            control: control,
                            deadline: context.deadline)
                    }
                    try self.requireAuthorizationDeadline(context)
                    return try await mutation(revalidatedReceipt)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch BrowserMCPPrivateInteropError.authorityUnavailable {
                await context.capabilities.invalidateNativeWindowBindings()
                throw BrowserNativeWindowBindingCoordinatorError.controlUnavailable
            }
        }
    }

    @MainActor
    private static func bindUnderAuthority(
        _ request: BindAuthorityRequest,
        control: BrowserMCPDevToolsControlSession) async throws
        -> BrowserNativeWindowBindingProof
    {
        let receipt: BrowserNativeWindowReceipt
        do {
            receipt = try BrowserNativeWindowReceiptResolver.capture(
                target: request.nativeTarget,
                providers: request.receiptProviders).get()
        } catch {
            throw BrowserNativeWindowBindingCoordinatorError.invalidNativeWindow
        }

        let candidates = try await self.candidates(
            control: control,
            requestedTargetID: request.privateTargetID,
            deadline: request.context.deadline)
        let currentReceipt = try BrowserNativeWindowReceiptResolver.revalidate(
            receipt,
            providers: request.receiptProviders).get()
        let correlation = try NativeBrowserWindowCorrelator.correlate(
            expectedNativeWindow: receipt.windowIdentity,
            currentNativeWindow: currentReceipt.windowIdentity,
            nativeTitle: nil,
            requestedTargetID: request.privateTargetID,
            candidates: candidates)
        let finalWindowID = try await control.getWindowForTarget(
            targetID: request.privateTargetID,
            deadline: request.context.deadline)
        _ = try BrowserNativeWindowReceiptResolver.revalidate(
            currentReceipt,
            providers: request.receiptProviders).get()
        guard finalWindowID == correlation.browserWindowID,
              await control.state() == .open
        else {
            throw BrowserNativeWindowBindingCoordinatorError.correlationRefused
        }
        try self.requireAuthorizationDeadline(request.context)
        try await request.context.capabilities.bindNativeWindow(
            pageReference: request.pageReference,
            sessionBinding: request.context.sessionBinding,
            privateTargetID: request.privateTargetID,
            privateBrowserWindowID: correlation.browserWindowID,
            nativeWindowReceipt: currentReceipt)
        return BrowserNativeWindowBindingProof(
            pageReference: request.pageReference,
            nativeWindowReceipt: currentReceipt,
            quality: .exact)
    }

    @MainActor
    private static func revalidateUnderAuthority(
        pageReference: String,
        context: Context,
        control: BrowserMCPDevToolsControlSession,
        receiptProviders: BrowserNativeWindowReceiptResolver.Providers) async throws
        -> BrowserNativeWindowReceipt
    {
        let binding = try await context.capabilities.nativeWindowBinding(
            pageReference: pageReference,
            sessionBinding: context.sessionBinding)
        let currentReceipt = try BrowserNativeWindowReceiptResolver.revalidate(
            binding.nativeWindowReceipt,
            providers: receiptProviders).get()
        let candidates = try await self.candidates(
            control: control,
            requestedTargetID: binding.privateTargetID,
            deadline: context.deadline)
        let correlation = try NativeBrowserWindowCorrelator.correlate(
            expectedNativeWindow: binding.nativeWindowReceipt.windowIdentity,
            currentNativeWindow: currentReceipt.windowIdentity,
            nativeTitle: nil,
            requestedTargetID: binding.privateTargetID,
            candidates: candidates)
        let finalWindowID = try await control.getWindowForTarget(
            targetID: binding.privateTargetID,
            deadline: context.deadline)
        let finalReceipt = try BrowserNativeWindowReceiptResolver.revalidate(
            currentReceipt,
            providers: receiptProviders).get()
        guard correlation.browserWindowID == binding.privateBrowserWindowID,
              finalWindowID == binding.privateBrowserWindowID,
              await control.state() == .open
        else {
            throw BrowserNativeWindowBindingCoordinatorError.correlationRefused
        }
        return finalReceipt
    }

    @MainActor
    private static func validationError(
        _ error: any Error,
        pageReference: String,
        capabilities: BrowserToolCapabilitySession,
        control: BrowserMCPDevToolsControlSession,
        deadline: ContinuousClock.Instant) async -> any Error
    {
        if error is CancellationError {
            if await control.state() == .open {
                await capabilities.invalidateNativeWindowBinding(pageReference: pageReference)
            } else {
                await capabilities.invalidateNativeWindowBindings()
            }
            return CancellationError()
        }
        if let controlError = error as? BrowserMCPDevToolsControlError,
           controlError == .cancelled
        {
            await capabilities.invalidateNativeWindowBindings()
            return CancellationError()
        }
        if let controlError = error as? BrowserMCPDevToolsControlError,
           case .timedOut = controlError
        {
            if await control.state() == .open {
                await capabilities.invalidateNativeWindowBinding(pageReference: pageReference)
            } else {
                await capabilities.invalidateNativeWindowBindings()
            }
            return BrowserNativeWindowBindingCoordinatorError.deadlineExceeded
        }
        if error is BrowserMCPDevToolsControlError,
           ContinuousClock.now >= deadline
        {
            if await control.state() == .open {
                await capabilities.invalidateNativeWindowBinding(pageReference: pageReference)
            } else {
                await capabilities.invalidateNativeWindowBindings()
            }
            return BrowserNativeWindowBindingCoordinatorError.deadlineExceeded
        }
        if let coordinatorError = error as? BrowserNativeWindowBindingCoordinatorError {
            if coordinatorError == .controlUnavailable {
                await capabilities.invalidateNativeWindowBindings()
            } else {
                await capabilities.invalidateNativeWindowBinding(pageReference: pageReference)
            }
            return coordinatorError
        }
        if error is BrowserMCPDevToolsControlError {
            guard await control.state() == .open else {
                await capabilities.invalidateNativeWindowBindings()
                return BrowserNativeWindowBindingCoordinatorError.controlUnavailable
            }
        }
        await capabilities.invalidateNativeWindowBinding(pageReference: pageReference)
        return BrowserNativeWindowBindingCoordinatorError.correlationRefused
    }

    private static func invalidateAfterPrivateLookupFailure(
        pageReference: String,
        context: Context) async
    {
        if await context.manager.nativeBindingAuthorityIsLive(
            expectedSessionBinding: context.sessionBinding)
        {
            await context.capabilities.invalidateNativeWindowBinding(pageReference: pageReference)
        } else {
            await context.capabilities.invalidateNativeWindowBindings()
        }
    }

    private static func requireAuthorizationDeadline(_ context: Context) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < context.deadline else {
            throw BrowserNativeWindowBindingCoordinatorError.deadlineExceeded
        }
    }

    private static func candidates(
        control: BrowserMCPDevToolsControlSession,
        requestedTargetID: String,
        deadline: ContinuousClock.Instant) async throws -> [CDPBrowserWindowCandidate]
    {
        let targets = try await control.getTargets(deadline: deadline).filter { $0.type == "page" }
        var targetIDsByWindow: [BrowserMCPDevToolsWindowID: Set<String>] = [:]
        var titlesByWindow: [BrowserMCPDevToolsWindowID: Set<String>] = [:]
        for target in targets {
            let windowID: BrowserMCPDevToolsWindowID
            do {
                windowID = try await control.getWindowForTarget(
                    targetID: target.targetID,
                    deadline: deadline)
            } catch BrowserMCPDevToolsControlError.staleTarget where target.targetID != requestedTargetID {
                continue
            }
            targetIDsByWindow[windowID, default: []].insert(target.targetID)
            if !target.title.isEmpty {
                titlesByWindow[windowID, default: []].insert(target.title)
            }
        }
        // chrome-devtools-mcp's private `get_tab_id` returns Puppeteer's tab target, while the default
        // Target.getTargets result contains page targets. Resolve the tab target explicitly so correlation
        // compares both identities in the same browser-window namespace without exposing either one.
        let requestedWindowID = try await control.getWindowForTarget(
            targetID: requestedTargetID,
            deadline: deadline)
        targetIDsByWindow[requestedWindowID, default: []].insert(requestedTargetID)

        var candidates: [CDPBrowserWindowCandidate] = []
        for windowID in targetIDsByWindow.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let bounds: BrowserMCPDevToolsWindowBounds
            do {
                bounds = try await control.getWindowBounds(windowID: windowID, deadline: deadline)
            } catch BrowserMCPDevToolsControlError.staleWindow where windowID != requestedWindowID {
                continue
            }
            guard let left = bounds.left,
                  let top = bounds.top,
                  let width = bounds.width,
                  let height = bounds.height,
                  width > 0,
                  height > 0,
                  bounds.state != .minimized
            else {
                continue
            }
            candidates.append(CDPBrowserWindowCandidate(
                windowID: windowID,
                bounds: CGRect(x: left, y: top, width: width, height: height),
                titles: titlesByWindow[windowID] ?? [],
                targetIDs: targetIDsByWindow[windowID] ?? []))
        }
        return candidates
    }
}
