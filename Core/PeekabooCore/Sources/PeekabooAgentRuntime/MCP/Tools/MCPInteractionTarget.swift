import Foundation
import PeekabooAutomation
import PeekabooFoundation

enum MCPInteractionTargetError: LocalizedError, Equatable {
    case applicationAndProcessIdentifier
    case multipleWindowSelectors
    case windowSelectorRequiresApp
    case invalidWindowId
    case invalidWindowIndex
    case invalidProcessIdentifier
    case backgroundTargetRequired
    case targetProcessNotFound
    case targetProcessIdentityUnavailable
    case backgroundWindowTargetAmbiguous
    case backgroundWindowTargetMismatch
    case backgroundTargetIneligible
    case backgroundTargetPlanningFailed(String)

    var refusalReason: DesktopActionOutcome.RefusalReason {
        switch self {
        case .targetProcessNotFound,
             .backgroundWindowTargetAmbiguous,
             .backgroundWindowTargetMismatch,
             .backgroundTargetIneligible,
             .backgroundTargetPlanningFailed:
            .targetUnavailable
        case .targetProcessIdentityUnavailable:
            .runtimeIncompatible
        case .applicationAndProcessIdentifier,
             .multipleWindowSelectors,
             .windowSelectorRequiresApp,
             .invalidWindowId,
             .invalidWindowIndex,
             .invalidProcessIdentifier,
             .backgroundTargetRequired:
            .invalidRequest
        }
    }

    var errorDescription: String? {
        switch self {
        case .applicationAndProcessIdentifier:
            "app and pid are mutually exclusive; provide exactly one process selector."
        case .multipleWindowSelectors:
            "window_id, window_title, and window_index are mutually exclusive; provide at most one."
        case .windowSelectorRequiresApp:
            "window_title and window_index require app or pid so the window can be resolved deterministically."
        case .invalidWindowId:
            "window_id must be between 1 and \(UInt32.max)."
        case .invalidWindowIndex:
            "window_index must be 0 or greater."
        case .invalidProcessIdentifier:
            "pid must be a positive 32-bit integer."
        case .backgroundTargetRequired:
            "Background keyboard input requires app or pid targeting. " +
                "Set foreground=true for intentional global input."
        case .targetProcessNotFound:
            "Could not resolve a running target process. Check the app/pid, or set foreground=true for intentional " +
                "global input."
        case .targetProcessIdentityUnavailable:
            "The runtime host could not pin the target to a process generation. " +
                "Update the host before background input."
        case .backgroundWindowTargetAmbiguous:
            "Background keyboard delivery could not resolve one exact window. " +
                "Add an exact window_id or fresh snapshot."
        case .backgroundWindowTargetMismatch:
            "The selected app, window, and snapshot do not identify the same exact process/window receipt."
        case .backgroundTargetIneligible:
            "The target cannot receive background input because it is a prohibited helper or its metadata is " +
                "incomplete."
        case let .backgroundTargetPlanningFailed(message):
            message
        }
    }
}

struct MCPInteractionFocusResult {
    let target: WindowTarget
    let actionResult: UIAutomationActionResult<Void>

    var outcome: DesktopActionOutcome {
        guard let outcome = self.actionResult.outcome else {
            preconditionFailure("A validated interaction focus result must retain its outcome")
        }
        return outcome
    }

    var targetIdentity: DesktopTargetIdentity {
        guard let targetIdentity = self.actionResult.targetIdentity else {
            preconditionFailure("A validated interaction focus result must retain its target")
        }
        return targetIdentity
    }

    func record(into sequence: inout DesktopActionSequenceAccumulator) {
        sequence.record(.reportedOutcome(self.outcome, defaultDispatchedUnitCount: .one))
    }

    func preservingFailure(
        _ error: any Error,
        operation: String) -> DesktopActionFailure
    {
        let leaf = error as? DesktopActionFailure ?? .preDispatchRefusal(
            reason: .operationUnsupported,
            message: error.localizedDescription,
            causeDescription: String(describing: error))
        let sequence = self.resultSequence()
        return sequence.failure(
            combining: leaf,
            operation: operation,
            requiresCompatibleOperationTarget: true,
            message: "\(operation) failed after its exact setup focus completed.",
            hint: "Observe the focused target before deciding whether to retry.",
            causeDescription: leaf.causeDescription ?? error.localizedDescription)
    }

    /// Composes an exact setup focus with a global pointer failure without attributing the
    /// shared-pointer leaf to the focused window.
    func preservingGlobalFailure(
        _ error: any Error,
        operation: String) -> DesktopActionFailure
    {
        let leaf = error as? DesktopActionFailure ?? .preDispatchRefusal(
            reason: .operationUnsupported,
            message: error.localizedDescription,
            causeDescription: String(describing: error))
        var sequence = self.resultSequence()
        sequence.record(
            outcome: nil,
            attribution: .targetless)
        return sequence.failure(
            combining: leaf,
            operation: operation,
            message: "\(operation) failed after its exact setup focus completed.",
            hint: "Observe the desktop before deciding whether to retry.",
            causeDescription: leaf.causeDescription ?? error.localizedDescription)
    }

    func attributing(_ failure: DesktopActionFailure) -> DesktopActionFailure {
        var sequence = UIAutomationActionResultSequenceAccumulator()
        sequence.record(
            outcome: nil,
            targetIdentity: self.targetIdentity,
            attribution: .operationTarget)
        return sequence.reconcilingTarget(of: failure)
    }

    func combining<Payload: Sendable>(
        _ leaf: UIAutomationActionResult<Payload>,
        operation: String) throws -> UIAutomationActionResult<Payload>
    {
        guard let leafOutcome = leaf.outcome else {
            throw self.preservingFailure(
                DesktopActionFailure.indeterminate(
                    evidence: .completionUnknown,
                    message: "\(operation) returned without a canonical outcome.",
                    hint: "Observe the target before retrying and update the runtime host."),
                operation: operation)
        }
        var sequence = self.resultSequence(targetProjectionPolicy: .coalescedIdentity)
        let step = DesktopActionSequenceAccumulator.Step.reportedOutcome(
            leafOutcome,
            defaultDispatchedUnitCount: .one)
        if let targetIdentity = leaf.targetIdentity {
            sequence.record(
                step,
                targetIdentity: targetIdentity,
                attribution: .operationTarget)
        } else {
            sequence.record(step)
        }
        return try sequence.result(
            payload: leaf.payload,
            operation: operation,
            requiresOutcome: true,
            requiresCompatibleTarget: true,
            failureMessage:
            "\(operation) returned untrustworthy target evidence after its exact setup focus completed.",
            failureHint: "Observe the focused target before deciding whether to retry.")
    }

    func preservingLeafResultFailure(
        _ error: any Error,
        leafOutcome: DesktopActionOutcome,
        leafTarget: DesktopActionTargetReceipt?,
        operation: String) -> DesktopActionFailure
    {
        let leafFailure = error as? DesktopActionFailure ?? .preDispatchRefusal(
            reason: .operationUnsupported,
            message: error.localizedDescription,
            causeDescription: String(describing: error))
        var sequence = self.resultSequence()
        let step = DesktopActionSequenceAccumulator.Step.reportedOutcome(
            leafOutcome,
            defaultDispatchedUnitCount: .one)
        if let leafTarget {
            sequence.record(
                step,
                targetIdentity: nil,
                targetReceipt: leafTarget,
                attribution: .operationTarget)
        } else {
            sequence.record(step)
        }
        return sequence.failure(
            combining: leafFailure,
            operation: operation,
            message: "\(operation) returned untrustworthy target evidence after its exact setup focus completed.",
            hint: "Observe the focused target before deciding whether to retry.",
            causeDescription: leafFailure.causeDescription ?? error.localizedDescription)
    }

    private func resultSequence(
        targetProjectionPolicy: UIAutomationActionResultSequenceAccumulator.TargetProjectionPolicy = .commonScope)
        -> UIAutomationActionResultSequenceAccumulator
    {
        var sequence = UIAutomationActionResultSequenceAccumulator(
            targetProjectionPolicy: targetProjectionPolicy)
        sequence.record(
            outcome: self.outcome,
            targetIdentity: self.targetIdentity,
            attribution: .sequenceTarget,
            defaultDispatchedUnitCount: .one)
        return sequence
    }
}

struct MCPInteractionTarget {
    let app: String?
    let pid: Int?
    let windowTitle: String?
    let windowIndex: Int?
    let windowId: Int?

    init(
        app: String?,
        pid: Int?,
        windowTitle: String?,
        windowIndex: Int?,
        windowId: Int?) throws
    {
        self.app = app
        self.pid = pid
        self.windowTitle = windowTitle
        self.windowIndex = windowIndex
        self.windowId = windowId
        try self.validate()
    }

    var appIdentifier: String? {
        if let pid {
            return "PID:\(pid)"
        }
        return self.app
    }

    var selector: InteractionTargetSelector {
        InteractionTargetSelector(
            applicationIdentifier: self.app,
            processIdentifier: self.pid,
            windowID: self.windowId,
            windowTitle: self.windowTitle,
            windowIndex: self.windowIndex)
    }

    func validate() throws {
        do {
            try self.selector.validate(policy: .interaction)
        } catch let error as InteractionTargetSelector.ValidationError {
            switch error {
            case .applicationAndProcessIdentifier:
                throw MCPInteractionTargetError.applicationAndProcessIdentifier
            case .multipleWindowSelectors:
                throw MCPInteractionTargetError.multipleWindowSelectors
            case .windowSelectorRequiresApplication:
                throw MCPInteractionTargetError.windowSelectorRequiresApp
            case .invalidProcessIdentifier:
                throw MCPInteractionTargetError.invalidProcessIdentifier
            case .invalidWindowID:
                throw MCPInteractionTargetError.invalidWindowId
            case .invalidWindowIndex:
                throw MCPInteractionTargetError.invalidWindowIndex
            case .conflictingProcessIdentifiers,
                 .invalidApplicationProcessIdentifier,
                 .missingTarget,
                 .emptyApplication,
                 .emptyWindowTitle:
                preconditionFailure("Interaction policy does not emit \(error)")
            }
        }
    }

    func toWindowTarget() throws -> WindowTarget? {
        try self.validate()
        switch try self.selector.normalizedWindowSelector(policy: .interaction) {
        case let .id(windowID):
            return .windowId(windowID)
        case let .title(title):
            if let appId = self.appIdentifier, !appId.isEmpty {
                return .applicationAndTitle(app: appId, title: title)
            }
            return .title(title)
        case let .index(index):
            return .index(app: self.appIdentifier ?? "", index: index)
        case nil:
            return self.appIdentifier.flatMap { $0.isEmpty ? nil : .application($0) }
        }
    }

    func focusIfRequested(windows: any WindowManagementServiceProtocol) async throws -> WindowTarget? {
        try await self.focusResultIfRequested(windows: windows)?.target
    }

    func focusResultIfRequested(
        windows: any WindowManagementServiceProtocol,
        onlyWhenTargeted: Bool = false) async throws -> MCPInteractionFocusResult?
    {
        guard !onlyWhenTargeted || self.hasTarget else { return nil }
        guard let requestedTarget = try self.toWindowTarget() else { return nil }
        let matches = try await windows.listWindows(target: requestedTarget)
        if self.selector.normalizedWindowTitle != nil, matches.count != 1 {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Foreground window-title targeting must resolve exactly one window.",
                hint: "Use a more specific title or select the window by ID after refreshing the window inventory.")
        }
        guard let window = matches.first,
              let identity = window.mutationIdentity,
              identity.windowID == window.windowID,
              let bounds = identity.capturedBounds,
              bounds == window.bounds
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Foreground focus requires one window with a stable exact target receipt.",
                hint: "Refresh the window inventory before retrying.")
        }
        let target = WindowTarget.windowId(window.windowID)
        let result = try await windows.focusWindowResult(
            target: target,
            expectedIdentity: identity)
        let validated = try windows.validatedWindowMutationResult(
            result,
            expectedIdentity: identity,
            operation: "Foreground setup focus")
        return MCPInteractionFocusResult(target: target, actionResult: validated)
    }

    var hasTarget: Bool {
        self.pid != nil || self.selector.normalizedApplicationIdentifier != nil || self.windowId != nil ||
            self.windowIndex != nil || self.selector.normalizedWindowTitle != nil
    }

    var hasWindowSelector: Bool {
        self.windowId != nil || self.windowIndex != nil || self.selector.normalizedWindowTitle != nil
    }

    @MainActor
    func requireBackgroundKeyboardTarget(
        applications: any ApplicationServiceProtocol,
        windows: any WindowManagementServiceProtocol,
        snapshotProcessIdentity: ApplicationProcessIdentity? = nil,
        snapshotExactWindow: UIAutomationTarget.ExactWindow? = nil,
        requiresExplicitExactWindow: Bool = false) async throws -> UIAutomationTarget
    {
        try self.validate()
        let planner = DesktopTargetPlanning.BackgroundKeyboardTargetPlanner(
            applications: applications,
            windows: windows)
        do {
            return try await planner.plan(
                selector: self.selector,
                snapshotProcessIdentity: snapshotProcessIdentity,
                snapshotExactWindow: snapshotExactWindow,
                requiresExplicitExactWindow: requiresExplicitExactWindow).target
        } catch DesktopTargetPlanning.BackgroundKeyboardTargetPlanningError.targetRequired {
            throw MCPInteractionTargetError.backgroundTargetRequired
        } catch DesktopTargetPlanning.BackgroundKeyboardTargetPlanningError.applicationIneligible {
            throw MCPInteractionTargetError.backgroundTargetIneligible
        } catch is DesktopTargetIdentityError {
            throw MCPInteractionTargetError.backgroundWindowTargetMismatch
        } catch let error as DesktopTargetPlanningError {
            switch error {
            case .applicationNotFound:
                throw MCPInteractionTargetError.targetProcessNotFound
            case .missingProcessIdentity, .invalidProcessIdentity, .staleApplication:
                throw MCPInteractionTargetError.targetProcessIdentityUnavailable
            case .windowNotFound, .ambiguousWindow:
                throw MCPInteractionTargetError.backgroundWindowTargetAmbiguous
            case .missingWindowIdentity, .incompleteWindowIdentity, .windowOwnerMismatch, .staleWindow:
                throw MCPInteractionTargetError.backgroundWindowTargetMismatch
            default:
                throw MCPInteractionTargetError.backgroundTargetPlanningFailed(error.localizedDescription)
            }
        } catch let error as DesktopTargetPlanning.BackgroundKeyboardTargetPlanningError {
            throw MCPInteractionTargetError.backgroundTargetPlanningFailed(error.localizedDescription)
        }
    }

    func focusIfRequested(windows: any WindowManagementServiceProtocol, onlyWhenTargeted: Bool) async throws
        -> WindowTarget?
    {
        try await self.focusResultIfRequested(
            windows: windows,
            onlyWhenTargeted: onlyWhenTargeted)?.target
    }

    func resolveWindowTitleIfNeeded(windows: any WindowManagementServiceProtocol) async throws -> String? {
        if let windowTitle, !windowTitle.isEmpty {
            return windowTitle
        }

        // Only attempt a lookup when the user used an ID/index selector.
        guard self.windowId != nil || self.windowIndex != nil else { return nil }
        guard let target = try self.toWindowTarget() else { return nil }

        let windowsInfo = try await windows.listWindows(target: target)
        return windowsInfo.first?.title
    }
}
