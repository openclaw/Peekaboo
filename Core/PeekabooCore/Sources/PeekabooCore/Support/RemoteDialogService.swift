import CoreGraphics
import Foundation
import PeekabooAgentRuntime
import PeekabooAutomation
import PeekabooBridge
import PeekabooFoundation

public struct RemoteDialogCapabilities: Sendable {
    public let backgroundButtonClick: Bool
    public let targetedList: Bool
    public let prepareAction: Bool
    public let exactClick: Bool
    public let exactDismiss: Bool
    public let exactInput: Bool

    public init(
        backgroundButtonClick: Bool = false,
        targetedList: Bool = false,
        prepareAction: Bool = false,
        exactClick: Bool = false,
        exactDismiss: Bool = false,
        exactInput: Bool = false)
    {
        self.backgroundButtonClick = backgroundButtonClick
        self.targetedList = targetedList
        self.prepareAction = prepareAction
        self.exactClick = exactClick
        self.exactDismiss = exactDismiss
        self.exactInput = exactInput
    }
}

@MainActor
public final class RemoteDialogService: DialogServiceProtocol {
    public let foregroundOutcomeRoute = DesktopActionOutcome.Route.bridge

    private let client: PeekabooBridgeClient
    private let supportsBackgroundButtonClick: Bool
    private let supportsTargetedList: Bool
    private let supportsPrepareAction: Bool
    private let supportsExactClick: Bool
    private let supportsExactDismiss: Bool
    private let supportsExactInput: Bool

    public convenience init(client: PeekabooBridgeClient, supportsBackgroundButtonClick: Bool) {
        self.init(
            client: client,
            capabilities: RemoteDialogCapabilities(backgroundButtonClick: supportsBackgroundButtonClick))
    }

    public init(
        client: PeekabooBridgeClient,
        capabilities: RemoteDialogCapabilities = RemoteDialogCapabilities())
    {
        self.client = client
        self.supportsBackgroundButtonClick = capabilities.backgroundButtonClick
        self.supportsTargetedList = capabilities.targetedList
        self.supportsPrepareAction = capabilities.prepareAction
        self.supportsExactClick = capabilities.exactClick
        self.supportsExactDismiss = capabilities.exactDismiss
        self.supportsExactInput = capabilities.exactInput
    }

    public func findActiveDialog(windowTitle: String?, appName: String?) async throws -> DialogInfo {
        try await self.client.dialogFindActive(windowTitle: windowTitle, appName: appName)
    }

    public func clickButton(buttonText: String, windowTitle: String?, appName: String?) async throws
        -> DialogActionResult
    {
        try await self.client.dialogClickButton(buttonText: buttonText, windowTitle: windowTitle, appName: appName)
    }

    public func clickButton(
        buttonText: String,
        windowTitle: String?,
        appName: String?,
        allowGlobalFallback: Bool) async throws -> DialogActionResult
    {
        if !allowGlobalFallback, !self.supportsBackgroundButtonClick {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Remote host does not support AX-only background dialog clicks; " +
                    "update the host or use --no-remote")
        }
        return try await self.client.dialogClickButton(
            buttonText: buttonText,
            windowTitle: windowTitle,
            appName: appName,
            allowGlobalFallback: allowGlobalFallback)
    }

    public func enterText(
        text: String,
        fieldIdentifier: String?,
        clearExisting: Bool,
        windowTitle: String?,
        appName: String?) async throws -> DialogActionResult
    {
        try await self.client.dialogEnterText(
            text: text,
            fieldIdentifier: fieldIdentifier,
            clearExisting: clearExisting,
            windowTitle: windowTitle,
            appName: appName)
    }

    public func enterText(_ request: DialogInputExecutionRequest) async throws -> DialogActionResult {
        guard self.supportsExactInput else {
            throw Self.capabilityRefusal(
                "Remote host does not advertise atomic exact dialog input; no input was sent.",
                minimumProtocol: "1.27")
        }
        do {
            return try await self.client.exactDialogEnterText(request)
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            throw Self.inputActionFailure(for: envelope)
        }
    }

    public func handleFileDialog(
        path: String?,
        filename: String?,
        actionButton: String?,
        ensureExpanded: Bool,
        appName: String?) async throws
        -> DialogActionResult
    {
        try await self.client.dialogHandleFile(
            path: path,
            filename: filename,
            actionButton: actionButton,
            ensureExpanded: ensureExpanded,
            appName: appName)
    }

    public func dismissDialog(force: Bool, windowTitle: String?, appName: String?) async throws -> DialogActionResult {
        try await self.client.dialogDismiss(force: force, windowTitle: windowTitle, appName: appName)
    }

    public func listDialogElements(windowTitle: String?, appName: String?) async throws -> DialogElements {
        try await self.client.dialogListElements(windowTitle: windowTitle, appName: appName)
    }

    public func prepareDialogAction(_ request: DialogActionPreparationRequest) async throws
        -> PreparedDialogActionReceipt
    {
        guard self.supportsPrepareAction, self.supportsAction(request.kind) else {
            throw Self.capabilityRefusal(
                "Remote host does not advertise the exact prepared dialog operation; update the host.")
        }
        do {
            return try await self.client.prepareDialogAction(request)
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            throw Self.preDispatchFailure(for: envelope)
        }
    }

    public func performPreparedDialogAction(_ receipt: PreparedDialogActionReceipt) async throws
        -> DialogActionResult
    {
        guard self.supportsPrepareAction, self.supportsAction(receipt.kind) else {
            throw Self.capabilityRefusal(
                "Remote host no longer advertises the prepared dialog operation; no action was sent.")
        }
        do {
            return try await self.client.performPreparedDialogAction(receipt)
        } catch let failure as DesktopActionFailure {
            // The shared transport converts every failure after request dispatch into a typed action failure.
            // Remaining raw transport errors prove the request was not fully written and stay retry-safe.
            throw failure
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            throw Self.actionFailure(for: envelope)
        }
    }

    public func listDialogElements(target: DialogTargetSelector) async throws -> DialogElements {
        guard self.supportsTargetedList else {
            throw Self.capabilityRefusal(
                "Remote host does not advertise uniquely targeted dialog listing; update the host.")
        }
        return try await self.client.targetedDialogListElements(target: target)
    }

    private func supportsAction(_ kind: DialogPreparedActionKind) -> Bool {
        switch kind {
        case .clickButton: self.supportsExactClick
        case .dismiss: self.supportsExactDismiss
        }
    }

    private static func capabilityRefusal(
        _ message: String,
        minimumProtocol: String = "1.25") -> DesktopActionFailure
    {
        .preDispatchRefusal(
            route: .bridge,
            reason: .runtimeIncompatible,
            message: message,
            hint: "Select a protocol \(minimumProtocol) host advertising the requested dialog operation.")
    }

    static func preDispatchFailure(for envelope: PeekabooBridgeErrorEnvelope) -> DesktopActionFailure {
        let reason: DesktopActionOutcome.RefusalReason = switch envelope.code {
        case .permissionDenied:
            .permissionDenied
        case .operationNotSupported, .versionMismatch, .decodingFailed:
            .runtimeIncompatible
        case .invalidRequest:
            .invalidRequest
        case .notFound, .serverBusy, .timeout, .unauthorizedClient, .internalError:
            .targetUnavailable
        }
        return .preDispatchRefusal(
            route: .bridge,
            reason: reason,
            message: envelope.message,
            hint: "Refresh the dialog target or update the selected Bridge host before retrying.",
            causeDescription: envelope.details)
    }

    static func actionFailure(for envelope: PeekabooBridgeErrorEnvelope) -> DesktopActionFailure {
        guard envelope.operationMayHaveCompleted else {
            return self.preDispatchFailure(for: envelope)
        }
        return .indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one,
            message: envelope.message,
            hint: "Observe the dialog before retrying; the exact action may already have completed.",
            causeDescription: envelope.details)
    }

    static func inputActionFailure(for envelope: PeekabooBridgeErrorEnvelope) -> DesktopActionFailure {
        guard envelope.operationMayHaveCompleted else {
            return self.preDispatchFailure(for: envelope)
        }
        return .indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: nil,
            message: envelope.message,
            hint: "Observe the dialog before retrying; the exact input may already have been delivered.",
            causeDescription: envelope.details)
    }
}
