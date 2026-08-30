// Window Focus Management Utilities
//
// This file provides comprehensive window focus management with support for:
// - Automatic window focusing before interactions
// - Space (virtual desktop) switching
// - Window movement between Spaces
// - Focus verification with retries
//
// ## Architecture
//
// The focus system has three layers:
//
// 1. **FocusOptions**: Command-line argument parsing for focus configuration
// 2. **FocusManagementService**: Core focus logic with Space support
// 3. **Integration**: Automatic focus in click, type, and menu commands
//
// ## Key Features
//
// 1. **Auto-Focus**: Automatically focus windows before interactions
// 2. **Space Switching**: Switch to window's Space if on different desktop
// 3. **Window Movement**: Bring windows to current Space
// 4. **Focus Verification**: Verify focus with configurable retries
// 5. **Snapshot Integration**: Store window IDs for fast refocusing
//
// ## Usage Examples
//
// ```swift
// // Command-line usage
// peekaboo click button --focus-timeout 3.0 --space-switch
// peekaboo type "Hello" --no-auto-focus
// peekaboo window focus --app Safari --move-here
//
// // Programmatic usage
// let service = FocusManagementService()
// let options = FocusManagementService.FocusOptions(
//     timeout: 5.0,
//     retryCount: 3,
//     switchSpace: true
// )
// try await service.focusWindow(windowID: 1234, options: options)
// ```
//

import AppKit
import ApplicationServices
import AXorcist
import Foundation
import PeekabooFoundation

private struct AttachedDialogFocusReceipt {
    let parentIdentity: WindowMutationIdentity
    let parentBounds: CGRect
    let dialog: Element
}

struct AttachedDialogFocusObservation: Sendable {
    let currentProcessStartIdentity: UInt64?
    let focusedWindowPID: pid_t?
    let frontmostPID: pid_t?
    let focusedWindowMatchesPreparedDialog: Bool
    let preparedDialogIsStructural: Bool
    let preparedDialogAttachedToParent: Bool
}

struct DialogDispatchFocusObservation: Sendable {
    let currentProcessStartIdentity: UInt64?
    let focusedWindowPID: pid_t?
    let frontmostPID: pid_t?
    let focusedWindowID: Int?
    let retainedParentMatches: Bool
    let focusedWindowMatchesPreparedDialog: Bool
    let preparedDialogIsStructural: Bool
    let preparedDialogAttachedToParent: Bool
    let focusedElementPID: pid_t?
    let focusedElementMatchesRetainedField: Bool
    let retainedFieldAttachedToDialog: Bool
}

struct FocusTargetIdentityObservation: Sendable {
    let processStartIdentity: UInt64?
    let windowOwnerProcessIdentifier: pid_t?
    let windowBounds: CGRect?
    let axProcessIdentifier: pid_t?
    let axWindowID: Int?
    let axBounds: CGRect?
}

func focusTargetIdentityMatches(
    expected: WindowMutationIdentity,
    observation: FocusTargetIdentityObservation) -> Bool
{
    guard observation.processStartIdentity == expected.ownerProcessStartIdentity else { return false }

    let hasWindowServerEvidence = observation.windowOwnerProcessIdentifier != nil || observation.windowBounds != nil
    if hasWindowServerEvidence {
        guard observation.windowOwnerProcessIdentifier == expected.ownerProcessIdentifier,
              observation.windowBounds == expected.capturedBounds
        else { return false }
    } else if expected.isMinimized != true {
        return false
    }

    let hasAXEvidence = observation.axProcessIdentifier != nil ||
        observation.axWindowID != nil ||
        observation.axBounds != nil
    if hasAXEvidence {
        guard observation.axProcessIdentifier == expected.ownerProcessIdentifier,
              observation.axWindowID == expected.windowID,
              observation.axBounds == expected.capturedBounds
        else { return false }
    }
    return true
}

private struct FocusWindowDispatchContext {
    let attachedDialog: AttachedDialogFocusReceipt?
    let expectedIdentity: WindowMutationIdentity?
    let dispatchGuard: FocusDispatchGuard?
    let onDispatch: ((FocusDispatchRecord) -> Void)?
}

enum FocusDispatchStage: Equatable, Sendable {
    case applicationActivation
    case setMainWindow
    case raiseWindow
    case spaceTransition
    case unspecified
}

@MainActor
final class FocusDispatchGuard {
    private let validateOwnership: @MainActor (FocusDispatchStage) throws -> Void
    private let validateAcceptedActivation: @MainActor () throws -> Void
    private let acceptedDispatch: @MainActor (FocusDispatchStage) throws -> Void
    private let completeDispatch: @MainActor (FocusDispatchStage) throws -> Void
    let requiresStrictDispatchOwnership: Bool
    private(set) var acceptedApplicationActivationDispatch = false
    private(set) var completedStrictTerminalDispatch = false

    init(validateOwnership: @escaping @MainActor () throws -> Void = {}) {
        self.requiresStrictDispatchOwnership = false
        self.validateOwnership = { _ in try validateOwnership() }
        self.validateAcceptedActivation = validateOwnership
        self.acceptedDispatch = { _ in }
        self.completeDispatch = { _ in }
    }

    init(
        requiresStrictDispatchOwnership: Bool,
        validateOwnership: @escaping @MainActor (FocusDispatchStage) throws -> Void,
        validateAcceptedActivation: (@MainActor () throws -> Void)? = nil,
        acceptedDispatch: @escaping @MainActor (FocusDispatchStage) throws -> Void = { _ in },
        completeDispatch: @escaping @MainActor (FocusDispatchStage) throws -> Void)
    {
        self.requiresStrictDispatchOwnership = requiresStrictDispatchOwnership
        self.validateOwnership = validateOwnership
        self.validateAcceptedActivation = validateAcceptedActivation ?? {
            try validateOwnership(.applicationActivation)
        }
        self.acceptedDispatch = acceptedDispatch
        self.completeDispatch = completeDispatch
    }

    func validate(_ stage: FocusDispatchStage = .unspecified) throws {
        try self.validateOwnership(stage)
    }

    func callAsFunction() throws {
        try self.validate()
    }

    func validateAcceptedActivationSettlement() throws {
        try self.validateAcceptedActivation()
    }

    func didAcceptDispatch(_ stage: FocusDispatchStage) throws {
        if stage == .applicationActivation {
            self.acceptedApplicationActivationDispatch = true
        }
        try self.acceptedDispatch(stage)
    }

    func didCompleteDispatch(_ stage: FocusDispatchStage = .unspecified) throws {
        try self.completeDispatch(stage)
        if self.requiresStrictDispatchOwnership, stage == .raiseWindow {
            self.completedStrictTerminalDispatch = true
        }
    }
}

@MainActor
enum FocusAcceptedActivationSettlement {
    typealias Sleep = @MainActor (Duration) async throws -> Void

    static func wait(
        dispatchGuard: FocusDispatchGuard?,
        pollCount: Int,
        interval: Duration,
        isSettled: @MainActor () -> Bool,
        sleep: Sleep = { try await Task.sleep(for: $0) }) async throws -> Bool
    {
        guard pollCount > 0 else { return false }

        for _ in 0..<pollCount {
            if isSettled() {
                return true
            }
            try dispatchGuard?.validateAcceptedActivationSettlement()
            try await sleep(interval)
        }
        if isSettled() {
            return true
        }
        try dispatchGuard?.validateAcceptedActivationSettlement()
        return false
    }
}

@MainActor
enum FocusRaiseSettlement {
    enum AttemptResult {
        case settled
        case retry(any Error)
    }

    static func run(
        attemptCount: Int,
        performAttempt: @MainActor () async throws -> AttemptResult,
        sleepBeforeRetry: @MainActor () async throws -> Void,
        fallbackError: @autoclosure @MainActor () -> any Error) async throws
    {
        guard attemptCount > 0 else { throw fallbackError() }
        var lastError: (any Error)?

        for attempt in 1...attemptCount {
            switch try await performAttempt() {
            case .settled:
                return
            case let .retry(error):
                lastError = error
                if attempt < attemptCount {
                    try await sleepBeforeRetry()
                }
            }
        }

        throw lastError ?? fallbackError()
    }

    static func attempt(
        requiresStrictDispatchOwnership: Bool,
        prepareAttempt: @MainActor () throws -> Void,
        dispatchRaise: @MainActor () throws -> Void,
        verifyFocus: @MainActor () async throws -> Void,
        completeRaise: @MainActor () throws -> Void) async throws -> AttemptResult
    {
        try prepareAttempt()
        var raiseDefinitelyReturned = false
        do {
            try dispatchRaise()
            raiseDefinitelyReturned = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if requiresStrictDispatchOwnership {
                throw error
            }
        }

        if raiseDefinitelyReturned, !requiresStrictDispatchOwnership {
            do {
                try completeRaise()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Non-strict completion errors historically defer to focus verification.
            }
        }

        do {
            try await verifyFocus()
        } catch {
            if requiresStrictDispatchOwnership, raiseDefinitelyReturned {
                throw error
            }
            // Only retryable verification failures return to the retry loop; terminal failures throw.
            return .retry(error)
        }

        if raiseDefinitelyReturned, requiresStrictDispatchOwnership {
            try completeRaise()
        }
        return .settled
    }
}

enum FocusDispatchRecord: Equatable, Sendable {
    case accepted(DesktopActionOutcome.Delivery)
    case mayHaveDispatched(DesktopActionOutcome.Delivery)

    var sequenceStep: DesktopActionSequenceAccumulator.Step {
        switch self {
        case let .accepted(delivery):
            .dispatched(route: .local, delivery: delivery, unitCount: .one)
        case let .mayHaveDispatched(delivery):
            .mayHaveDispatched(route: .local, delivery: delivery, unitCount: .one)
        }
    }
}

enum FocusDispatchAccounting {
    @discardableResult
    static func acceptingBool(
        delivery: DesktopActionOutcome.Delivery,
        onDispatch: ((FocusDispatchRecord) -> Void)?,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() },
        operation: () -> Bool) throws -> Bool
    {
        try checkCancellation()
        let accepted = operation()
        if accepted {
            onDispatch?(.accepted(delivery))
        }
        return accepted
    }

    static func submittingThrowing<Value>(
        delivery: DesktopActionOutcome.Delivery,
        onDispatch: ((FocusDispatchRecord) -> Void)?,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() },
        operation: () throws -> Value) throws -> Value
    {
        try checkCancellation()
        do {
            let value = try operation()
            onDispatch?(.accepted(delivery))
            return value
        } catch {
            onDispatch?(.mayHaveDispatched(delivery))
            throw error
        }
    }

    static func submittingAsync<Value>(
        delivery: DesktopActionOutcome.Delivery,
        onDispatch: ((FocusDispatchRecord) -> Void)?,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() },
        operation: () async throws -> Value) async throws -> Value
    {
        try checkCancellation()
        do {
            let value = try await operation()
            onDispatch?(.accepted(delivery))
            return value
        } catch {
            onDispatch?(.mayHaveDispatched(delivery))
            throw error
        }
    }

    static func shouldAccountSpaceSwitch(isActive: Bool?) -> Bool {
        isActive != true
    }

    static func report(
        outcome: DesktopActionOutcome,
        onDispatch: ((FocusDispatchRecord) -> Void)?)
    {
        guard let delivery = outcome.delivery else { return }
        switch outcome.dispatchState {
        case let .dispatched(unitCount):
            for _ in 0..<(unitCount?.rawValue ?? 1) {
                onDispatch?(.accepted(delivery))
            }
        case let .mayHaveDispatched(unitCount):
            for _ in 0..<(unitCount?.rawValue ?? 1) {
                onDispatch?(.mayHaveDispatched(delivery))
            }
        case .none:
            break
        }
    }

    static func verifiedFocusOutcome(
        _ resolution: DesktopActionSequenceAccumulator.Resolution) -> DesktopActionOutcome
    {
        switch resolution.mutationDisposition {
        case .none:
            if let outcome = resolution.outcome, outcome.state == .confirmedNoChange {
                return outcome
            }
            return .confirmedNoChange()
        case let .definite(unitCount):
            guard let outcome = resolution.outcome else {
                return .indeterminate(
                    route: .local,
                    evidence: .completionUnknown,
                    unitCount: unitCount)
            }
            guard outcome.state == .dispatchedUnverified,
                  let delivery = outcome.delivery
            else { return outcome }
            return .confirmedChange(
                route: outcome.route,
                delivery: delivery,
                unitCount: outcome.dispatchState.unitCount ?? unitCount)
        case let .possible(unitCount):
            return resolution.outcome ?? .indeterminate(
                route: .local,
                evidence: .completionUnknown,
                unitCount: unitCount)
        }
    }

    static func reportPinnedSpaceOutcome(
        _ result: UIAutomationActionResult<Void>,
        expectedIdentity: WindowMutationIdentity,
        requiredDeliveryMode: DesktopActionOutcome.Delivery.Mode,
        operation: String,
        onDispatch: ((FocusDispatchRecord) -> Void)?) throws
    {
        let outcome = try self.requirePinnedSpaceOutcome(
            result,
            expectedIdentity: expectedIdentity,
            requiredDeliveryMode: requiredDeliveryMode,
            operation: operation)
        self.report(outcome: outcome, onDispatch: onDispatch)
    }

    static func requirePinnedSpaceOutcome(
        _ result: UIAutomationActionResult<Void>,
        expectedIdentity: WindowMutationIdentity,
        requiredDeliveryMode: DesktopActionOutcome.Delivery.Mode,
        operation: String) throws -> DesktopActionOutcome
    {
        let targetReceipt = expectedIdentity.actionTargetReceipt
        let expectedWindow: UIAutomationTarget.ExactWindow
        do {
            guard let capturedBounds = expectedIdentity.capturedBounds else {
                throw PeekabooError.snapshotStale("Exact-window Space focus identity has no captured bounds")
            }
            expectedWindow = try UIAutomationTarget.ExactWindow(
                identity: expectedIdentity,
                bounds: capturedBounds)
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "\(operation) received an incomplete exact-window identity.",
                hint: "Refresh the exact window before retrying.",
                causeDescription: error.localizedDescription)
                .attributed(to: targetReceipt)
        }
        let expectedTarget = DesktopTargetIdentity(exactWindow: expectedWindow)
        guard result.outcome != nil else {
            throw DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .nativeFramework, mode: requiredDeliveryMode),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "\(operation) returned without its required canonical outcome.",
                hint: "Observe the exact window and active Space before retrying.")
                .attributed(to: expectedTarget.actionTargetReceipt)
        }
        return try UIAutomationActionResultSemantics.requireAcceptedOutcome(
            result,
            policy: .confirmedOrDispatched(requiring: requiredDeliveryMode),
            targetRequirement: .exact(expectedTarget),
            operation: operation,
            missingTargetMessage: "\(operation) returned a missing or mismatched exact-window target.")
    }
}

enum FocusSpaceActionPlan: Equatable, Sendable {
    case moveToCurrentSpace(expectedIdentity: WindowMutationIdentity?)
    case switchToWindowSpace(expectedIdentity: WindowMutationIdentity?)

    static func make(
        bringToCurrentSpace: Bool,
        expectedIdentity: WindowMutationIdentity?) -> Self
    {
        if bringToCurrentSpace {
            .moveToCurrentSpace(expectedIdentity: expectedIdentity)
        } else {
            .switchToWindowSpace(expectedIdentity: expectedIdentity)
        }
    }
}

// MARK: - Focus Options Protocol

public protocol FocusOptionsProtocol {
    var autoFocus: Bool { get }
    var focusTimeout: TimeInterval? { get }
    var focusRetryCount: Int? { get }
    var spaceSwitch: Bool { get }
    var bringToCurrentSpace: Bool { get }
}

// MARK: - Focus Options Value Type

public struct FocusOptions: FocusOptionsProtocol {
    public let autoFocus: Bool
    public let focusTimeout: TimeInterval?
    public let focusRetryCount: Int?
    public let spaceSwitch: Bool
    public let bringToCurrentSpace: Bool

    public init(
        autoFocus: Bool = true,
        focusTimeout: TimeInterval? = nil,
        focusRetryCount: Int? = nil,
        spaceSwitch: Bool = false,
        bringToCurrentSpace: Bool = false)
    {
        self.autoFocus = autoFocus
        self.focusTimeout = focusTimeout
        self.focusRetryCount = focusRetryCount
        self.spaceSwitch = spaceSwitch
        self.bringToCurrentSpace = bringToCurrentSpace
    }
}

// MARK: - Focus Command Extension

// MARK: - Focus Management Service

@MainActor
public final class FocusManagementService {
    private let windowIdentityService = WindowIdentityService()
    private let spaceService = SpaceManagementService()
    private let applications: any ApplicationServiceProtocol
    private let operationLaneCoordinator: DesktopOperationLaneCoordinator

    public init(
        applications: (any ApplicationServiceProtocol)? = nil,
        operationLaneCoordinator: DesktopOperationLaneCoordinator = .shared)
    {
        self.applications = applications ?? ApplicationService()
        self.operationLaneCoordinator = operationLaneCoordinator
    }

    public struct FocusOptions {
        public let timeout: TimeInterval
        public let retryCount: Int
        public let switchSpace: Bool
        public let bringToCurrentSpace: Bool

        public init(
            timeout: TimeInterval = 5.0,
            retryCount: Int = 3,
            switchSpace: Bool = true,
            bringToCurrentSpace: Bool = false)
        {
            self.timeout = timeout
            self.retryCount = retryCount
            self.switchSpace = switchSpace
            self.bringToCurrentSpace = bringToCurrentSpace
        }
    }

    // MARK: - Window Finding

    /// Find the best window match for the given criteria
    public func findBestWindow(
        applicationName: String,
        windowTitle: String? = nil) async throws -> CGWindowID?
    {
        // Find the application
        let appInfo = try await self.applications.findApplication(identifier: applicationName)

        guard let app = NSRunningApplication(processIdentifier: appInfo.processIdentifier) else {
            throw FocusError.applicationNotRunning(applicationName)
        }

        // Get all windows for the app
        let windows = self.windowIdentityService.getWindows(for: app)

        guard !windows.isEmpty else {
            throw FocusError.noWindowsFound(applicationName)
        }

        let prioritizedWindows = self.prioritizeWindows(windows)

        // If window title specified, try to find a match
        if let title = windowTitle {
            if let matchingWindow = prioritizedWindows.first(where: { self.matchesWindow($0, title: title) })
                ?? windows.first(where: { self.matchesWindow($0, title: title) })
            {
                return matchingWindow.windowID
            }
            // If no match found, fall through to get frontmost
        }

        // Return the frontmost window (first in list)
        return prioritizedWindows.first?.windowID ?? windows.first?.windowID
    }

    // MARK: - Focus Operations

    /// Focus a window by its CGWindowID
    public func focusWindow(windowID: CGWindowID, options: FocusOptions = FocusOptions()) async throws {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            try await self.focusWindowWithOwnedLane(windowID: windowID, options: options)
        }
    }

    /// Focus a window while retaining exact native dispatch accounting.
    public func focusWindowResult(
        windowID: CGWindowID,
        options: FocusOptions = FocusOptions(),
        expectedIdentity: WindowMutationIdentity? = nil) async throws -> DesktopActionOutcome
    {
        var sequence = DesktopActionSequenceAccumulator()
        do {
            try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
                try await self.focusWindowWithOwnedLane(
                    windowID: windowID,
                    options: options,
                    expectedIdentity: expectedIdentity,
                    onDispatch: { record in
                        sequence.record(record.sequenceStep)
                    })
            }
        } catch is CancellationError {
            if let failure = sequence.cancellationFailure(
                fallbackRoute: .local,
                message: "Window focus was cancelled after dispatch may have begun.",
                hint: "Observe the exact window before retrying focus.",
                causeDescription: "Focus task cancelled")
            {
                throw failure
            }
            throw CancellationError()
        } catch {
            guard sequence.mutationDisposition.mutationDispatched else { throw error }
            let leaf = error as? DesktopActionFailure ?? .preDispatchRefusal(
                reason: .operationUnsupported,
                message: error.localizedDescription,
                hint: "Observe the exact window before retrying focus.",
                causeDescription: String(describing: error))
            throw sequence.failure(
                combining: leaf,
                message: "Window focus did not complete with a verified exact target.",
                hint: "Observe the exact window before retrying focus.")
        }
        return FocusDispatchAccounting.verifiedFocusOutcome(sequence.successResolution())
    }

    func focusWindowWithOwnedLane(
        windowID: CGWindowID,
        options: FocusOptions = FocusOptions(),
        expectedIdentity: WindowMutationIdentity? = nil,
        dispatchGuard: FocusDispatchGuard? = nil,
        onDispatch: ((FocusDispatchRecord) -> Void)? = nil) async throws
    {
        try await self.focusWindowWithOwnedLane(
            windowID: windowID,
            options: options,
            context: FocusWindowDispatchContext(
                attachedDialog: nil,
                expectedIdentity: expectedIdentity,
                dispatchGuard: dispatchGuard,
                onDispatch: onDispatch))
    }

    /// Focus an exact parent window while accepting only its already-prepared modal descendant.
    ///
    /// Sheets frequently become the application's AX focused window even though callers selected
    /// the owning document window by its WindowServer ID. This overload is deliberately internal
    /// and dialog-specific so ordinary coordinate/keyboard focus never broadens to another window
    /// in the process.
    func focusDialogWindowWithOwnedLane(
        target: UIAutomationTarget.ExactWindow,
        dialog: Element,
        options: FocusOptions = FocusOptions()) async throws
    {
        try await self.focusWindowWithOwnedLane(
            windowID: CGWindowID(target.identity.windowID),
            options: options,
            context: FocusWindowDispatchContext(
                attachedDialog: AttachedDialogFocusReceipt(
                    parentIdentity: target.identity,
                    parentBounds: target.bounds,
                    dialog: dialog),
                expectedIdentity: target.identity,
                dispatchGuard: nil,
                onDispatch: nil))
    }

    /// Verify an already-focused exact dialog without activating, raising, or changing Spaces.
    func requireDialogWindowFocusWithOwnedLane(
        target: UIAutomationTarget.ExactWindow,
        dialog: Element,
        timeout: TimeInterval) async throws
    {
        let windowID = CGWindowID(target.identity.windowID)
        guard self.windowIdentityService.windowExists(windowID: windowID),
              SystemIdentityResolver.validateWindowMutationIdentity(
                  target.identity,
                  expectedBounds: target.bounds),
              let handle = self.windowIdentityService.findWindow(
                  byID: windowID,
                  messagingTimeout: Float(min(timeout, 0.5)))
        else {
            throw FocusError.windowNotFound(windowID)
        }
        try await self.verifyWindowFocus(
            handle.element,
            windowID: windowID,
            timeout: timeout,
            attachedDialog: AttachedDialogFocusReceipt(
                parentIdentity: target.identity,
                parentBounds: target.bounds,
                dialog: dialog),
            expectedIdentity: target.identity)
    }

    /// Perform the final non-mutating focus check immediately before global keyboard delivery.
    func requireDialogDispatchFocus(
        target: UIAutomationTarget.ExactWindow,
        retainedWindow: Element,
        dialog: Element,
        field: Element) throws
    {
        let windowID = CGWindowID(target.identity.windowID)
        guard SystemIdentityResolver.validateWindowMutationIdentity(
            target.identity,
            expectedBounds: target.bounds),
            let currentWindow = self.windowIdentityService.findWindow(
                byID: windowID,
                messagingTimeout: 0.1),
            let ownerPID = currentWindow.element.pid(),
            ownerPID == target.identity.ownerProcessIdentifier,
            let runningApp = NSRunningApplication(processIdentifier: ownerPID),
            let focusedWindow = self.focusedWindow(for: runningApp, timeout: 0.1),
            let focusedElement = self.focusedElement(for: runningApp, timeout: 0.1)
        else {
            throw FocusError.focusVerificationFailed(windowID)
        }
        let focusedWindowID = self.windowIdentityService.getWindowID(
            from: focusedWindow,
            messagingTimeout: 0.1)
        let observation = DialogDispatchFocusObservation(
            currentProcessStartIdentity: SystemIdentityResolver.processStartIdentity(ownerPID),
            focusedWindowPID: focusedWindow.pid(),
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            focusedWindowID: focusedWindowID.map(Int.init),
            retainedParentMatches: DialogService.sameElement(currentWindow.element, retainedWindow),
            focusedWindowMatchesPreparedDialog: DialogService.sameElement(focusedWindow, dialog),
            preparedDialogIsStructural: DialogElementClassifier.isStructuralDialog(
                DialogElementClassifier.evidence(for: dialog)),
            preparedDialogAttachedToParent: DialogService.rawElementPresence(
                dialog,
                in: currentWindow.element) == .present,
            focusedElementPID: focusedElement.pid(),
            focusedElementMatchesRetainedField: DialogService.sameElement(focusedElement, field),
            retainedFieldAttachedToDialog: DialogService.rawElementPresence(
                field,
                in: dialog) == .present)
        guard Self.isVerifiedDialogDispatchFocus(
            expectedParent: target.identity,
            observation: observation)
        else {
            throw FocusError.focusVerificationFailed(windowID)
        }
    }

    /// Perform the final synchronous focus proof immediately before a global dialog key event.
    /// Callers must not suspend between this check and dispatch.
    func requireDialogGlobalKeyboardFocus(
        target: UIAutomationTarget.ExactWindow,
        retainedWindow: Element,
        dialog: Element) throws
    {
        let windowID = CGWindowID(target.identity.windowID)
        guard SystemIdentityResolver.validateWindowMutationIdentity(
            target.identity,
            expectedBounds: target.bounds),
            let currentWindow = self.windowIdentityService.findWindow(
                byID: windowID,
                messagingTimeout: 0.1),
            DialogService.sameElement(currentWindow.element, retainedWindow),
            let ownerPID = currentWindow.element.pid(),
            ownerPID == target.identity.ownerProcessIdentifier,
            let runningApp = NSRunningApplication(processIdentifier: ownerPID),
            let focusedWindow = self.focusedWindow(for: runningApp, timeout: 0.1)
        else {
            throw FocusError.focusVerificationFailed(windowID)
        }
        let observation = AttachedDialogFocusObservation(
            currentProcessStartIdentity: SystemIdentityResolver.processStartIdentity(ownerPID),
            focusedWindowPID: focusedWindow.pid(),
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            focusedWindowMatchesPreparedDialog: DialogService.sameElement(focusedWindow, dialog),
            preparedDialogIsStructural: DialogElementClassifier.isStructuralDialog(
                DialogElementClassifier.evidence(for: dialog)),
            preparedDialogAttachedToParent: DialogService.rawElementPresence(
                dialog,
                in: currentWindow.element) == .present)
        guard Self.isVerifiedAttachedDialogFocus(
            expectedParent: target.identity,
            observation: observation)
        else {
            throw FocusError.focusVerificationFailed(windowID)
        }
    }

    private func focusWindowWithOwnedLane(
        windowID: CGWindowID,
        options: FocusOptions,
        context: FocusWindowDispatchContext) async throws
    {
        let attachedDialog = context.attachedDialog
        let expectedIdentity = context.expectedIdentity
        let dispatchGuard = context.dispatchGuard
        let onDispatch = context.onDispatch
        // Verify window exists before any focus work starts.
        guard self.windowIdentityService.windowExists(windowID: windowID) else {
            throw FocusError.windowNotFound(windowID)
        }
        try self.requireExpectedFocusIdentity(expectedIdentity, windowID: windowID)
        if expectedIdentity != nil {
            guard let preflightHandle = self.windowIdentityService.findWindow(byID: windowID) else {
                throw FocusError.axElementNotFound(windowID)
            }
            try self.requireExpectedFocusIdentity(
                expectedIdentity,
                windowID: windowID,
                element: preflightHandle.element)
        }

        if let attachedDialog,
           !SystemIdentityResolver.validateWindowMutationIdentity(
               attachedDialog.parentIdentity,
               expectedBounds: attachedDialog.parentBounds)
        {
            throw FocusError.focusVerificationFailed(windowID)
        }

        // Handle Space switching if needed.
        if options.switchSpace || options.bringToCurrentSpace {
            try await self.handleSpaceFocus(
                windowID: windowID,
                bringToCurrentSpace: options.bringToCurrentSpace,
                expectedIdentity: expectedIdentity,
                dispatchGuard: dispatchGuard,
                onDispatch: onDispatch)
            try self.requireExpectedFocusIdentity(expectedIdentity, windowID: windowID)
        }

        // Resolve once to identify the owning app; AX handles can go stale after activation.
        guard let initialHandle = self.windowIdentityService.findWindow(byID: windowID) else {
            throw FocusError.axElementNotFound(windowID)
        }
        try self.requireExpectedFocusIdentity(
            expectedIdentity,
            windowID: windowID,
            element: initialHandle.element)

        let runningApp = initialHandle.app.application

        var activationAccepted = false
        if !runningApp.isActive {
            try self.requireExpectedFocusIdentity(
                expectedIdentity,
                windowID: windowID,
                element: initialHandle.element)
            try dispatchGuard?.validate(.applicationActivation)
            activationAccepted = try FocusDispatchAccounting.acceptingBool(
                delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                onDispatch: onDispatch,
                operation: { runningApp.activate() })
            if activationAccepted {
                try dispatchGuard?.didAcceptDispatch(.applicationActivation)
            }
        }

        let activationSettled: Bool
        if activationAccepted {
            activationSettled = try await FocusAcceptedActivationSettlement.wait(
                dispatchGuard: dispatchGuard,
                pollCount: 30,
                interval: .milliseconds(100),
                isSettled: {
                    runningApp.isActive ||
                        NSWorkspace.shared.frontmostApplication?.processIdentifier == runningApp.processIdentifier
                })
        } else {
            try await self.waitForCondition(
                timeout: 3.0,
                interval: 0.1,
                condition: {
                    runningApp.isActive ||
                        NSWorkspace.shared.frontmostApplication?.processIdentifier == runningApp.processIdentifier
                })
            activationSettled = true
        }
        guard activationSettled else {
            throw FocusError.timeoutWaitingForCondition
        }
        if activationAccepted {
            try dispatchGuard?.didCompleteDispatch(.applicationActivation)
        }

        guard let refreshedHandle = self.windowIdentityService.findWindow(byID: windowID, in: runningApp) ??
            self.windowIdentityService.findWindow(byID: windowID)
        else {
            throw FocusError.axElementNotFound(windowID)
        }
        try self.requireExpectedFocusIdentity(
            expectedIdentity,
            windowID: windowID,
            element: refreshedHandle.element)

        if attachedDialog != nil {
            do {
                try await self.verifyWindowFocus(
                    refreshedHandle.element,
                    windowID: windowID,
                    timeout: min(options.timeout, 0.15),
                    attachedDialog: attachedDialog,
                    expectedIdentity: expectedIdentity)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The prepared dialog is not focused yet; foreground consent permits the normal raise path.
            }
        }

        try await self.focusWindowElement(
            refreshedHandle.element,
            windowID: windowID,
            options: options,
            context: context)
    }

    // MARK: - Private Helpers

    private func handleSpaceFocus(
        windowID: CGWindowID,
        bringToCurrentSpace: Bool,
        expectedIdentity: WindowMutationIdentity?,
        dispatchGuard: FocusDispatchGuard?,
        onDispatch: ((FocusDispatchRecord) -> Void)?) async throws
    {
        switch FocusSpaceActionPlan.make(
            bringToCurrentSpace: bringToCurrentSpace,
            expectedIdentity: expectedIdentity)
        {
        case let .moveToCurrentSpace(.some(identity)):
            try dispatchGuard?.validate(.spaceTransition)
            let result = try self.spaceService.moveWindowToCurrentSpaceResult(
                windowID: windowID,
                expectedIdentity: identity)
            try FocusDispatchAccounting.reportPinnedSpaceOutcome(
                result,
                expectedIdentity: identity,
                requiredDeliveryMode: .background,
                operation: "Exact-window move to current Space",
                onDispatch: onDispatch)

        case .moveToCurrentSpace(.none):
            try dispatchGuard?.validate(.spaceTransition)
            try FocusDispatchAccounting.submittingThrowing(
                delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                onDispatch: onDispatch,
                operation: { try self.spaceService.moveWindowToCurrentSpace(windowID: windowID) })

        case let .switchToWindowSpace(.some(identity)):
            try dispatchGuard?.validate(.spaceTransition)
            let result = try await self.spaceService.switchToWindowSpaceResult(
                windowID: windowID,
                expectedIdentity: identity)
            try FocusDispatchAccounting.reportPinnedSpaceOutcome(
                result,
                expectedIdentity: identity,
                requiredDeliveryMode: .foreground,
                operation: "Exact-window Space switch",
                onDispatch: onDispatch)

        case .switchToWindowSpace(.none):
            let isActive = self.spaceService.getSpacesForWindow(windowID: windowID).first?.isActive
            if FocusDispatchAccounting.shouldAccountSpaceSwitch(isActive: isActive) {
                try dispatchGuard?.validate(.spaceTransition)
                try await FocusDispatchAccounting.submittingAsync(
                    delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                    onDispatch: onDispatch,
                    operation: { try await self.spaceService.switchToWindowSpace(windowID: windowID) })
            } else {
                try dispatchGuard?.validate(.spaceTransition)
                try await self.spaceService.switchToWindowSpace(windowID: windowID)
            }
        }

        // Give macOS time to complete the Space transition
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
    }

    private func requireExpectedFocusIdentity(
        _ expectedIdentity: WindowMutationIdentity?,
        windowID: CGWindowID,
        element: Element? = nil) throws
    {
        guard let expectedIdentity else { return }
        guard Int(windowID) == expectedIdentity.windowID else {
            throw PeekabooError.windowNotFound(criteria: "windowId \(windowID) contradicts focus receipt")
        }
        let windowServerIdentity = SystemIdentityResolver.windowIdentity(windowID)
        let axBounds: CGRect? = element.flatMap { element in
            guard let position = element.position(), let size = element.size() else { return nil }
            return CGRect(origin: position, size: size)
        }
        let observation = FocusTargetIdentityObservation(
            processStartIdentity: SystemIdentityResolver.processStartIdentity(
                expectedIdentity.ownerProcessIdentifier),
            windowOwnerProcessIdentifier: windowServerIdentity?.ownerProcessIdentifier,
            windowBounds: windowServerIdentity?.bounds,
            axProcessIdentifier: element?.pid(),
            axWindowID: element.flatMap { self.windowIdentityService.getWindowID(from: $0).map(Int.init) },
            axBounds: axBounds)
        guard focusTargetIdentityMatches(expected: expectedIdentity, observation: observation) else {
            throw PeekabooError.windowNotFound(criteria: "windowId \(windowID) changed exact focus identity")
        }
    }

    private func focusWindowElement(
        _ windowElement: Element,
        windowID: CGWindowID,
        options: FocusOptions,
        context: FocusWindowDispatchContext) async throws
    {
        try await FocusRaiseSettlement.run(
            attemptCount: options.retryCount,
            performAttempt: {
                try await FocusRaiseSettlement.attempt(
                    requiresStrictDispatchOwnership: context.dispatchGuard?.requiresStrictDispatchOwnership == true,
                    prepareAttempt: {
                        // Chrome and other multi-window apps can raise a window without updating AXFocusedWindow.
                        // Ask AX to make it main as well, then require both AX and Workspace to confirm the result.
                        try self.requireExpectedFocusIdentity(
                            context.expectedIdentity,
                            windowID: windowID,
                            element: windowElement)
                        try context.dispatchGuard?.validate(.setMainWindow)
                        let madeMain = try FocusDispatchAccounting.acceptingBool(
                            delivery: .init(mechanism: .accessibilityValue, mode: .foreground),
                            onDispatch: context.onDispatch,
                            operation: {
                                windowElement.setValue(true, forAttribute: AXAttributeNames.kAXMainAttribute)
                            })
                        if madeMain {
                            // Strict completion/ownership sentinels must escape immediately after an accepted
                            // set-main dispatch.
                            try context.dispatchGuard?.didCompleteDispatch(.setMainWindow)
                        }
                    },
                    dispatchRaise: {
                        try self.requireExpectedFocusIdentity(
                            context.expectedIdentity,
                            windowID: windowID,
                            element: windowElement)
                        try context.dispatchGuard?.validate(.raiseWindow)
                        _ = try FocusDispatchAccounting.submittingThrowing(
                            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                            onDispatch: context.onDispatch,
                            operation: { try windowElement.performAction(.raise) })
                    },
                    verifyFocus: {
                        try await self.verifyWindowFocus(
                            windowElement,
                            windowID: windowID,
                            timeout: options.timeout,
                            attachedDialog: context.attachedDialog,
                            expectedIdentity: context.expectedIdentity)
                    },
                    completeRaise: {
                        // Accepted AXRaise is terminal only after the exact focus observation settles.
                        // Keeping this outside verification handling lets strict sentinels escape.
                        try context.dispatchGuard?.didCompleteDispatch(.raiseWindow)
                    })
            },
            sleepBeforeRetry: {
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5s between retries
            },
            fallbackError: FocusError.focusVerificationFailed(windowID))
    }

    private func verifyWindowFocus(
        _ windowElement: Element,
        windowID: CGWindowID,
        timeout: TimeInterval,
        attachedDialog: AttachedDialogFocusReceipt?,
        expectedIdentity: WindowMutationIdentity? = nil) async throws
    {
        guard let ownerPID = Self.processIdentifier(for: windowElement.underlyingElement),
              let runningApp = NSRunningApplication(processIdentifier: ownerPID)
        else {
            throw FocusError.focusVerificationFailed(windowID)
        }
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            try self.requireExpectedFocusIdentity(
                expectedIdentity,
                windowID: windowID,
                element: windowElement)
            let remainingTimeout = timeout - Date().timeIntervalSince(startTime)
            let isMinimized = windowElement.isMinimized() ?? false
            let focusedWindow = self.focusedWindow(
                for: runningApp,
                timeout: min(0.1, remainingTimeout))
            let focusedWindowID = focusedWindow.flatMap {
                self.windowIdentityService.getWindowID(
                    from: $0,
                    messagingTimeout: Float(min(0.1, remainingTimeout)))
            }
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let preparedGenerationMatches = attachedDialog.map {
                SystemIdentityResolver.processStartIdentity(ownerPID) == $0.parentIdentity.ownerProcessStartIdentity
            } ?? true

            if !isMinimized, preparedGenerationMatches, Self.isVerifiedParentWindowFocus(
                targetWindowID: windowID,
                ownerPID: ownerPID,
                focusedWindowID: focusedWindowID,
                frontmostPID: frontmostPID,
                hasAttachedDialog: attachedDialog != nil)
            {
                return
            }

            if !isMinimized,
               let attachedDialog,
               let focusedWindow,
               Self.isVerifiedAttachedDialogFocus(
                   expectedParent: attachedDialog.parentIdentity,
                   observation: AttachedDialogFocusObservation(
                       currentProcessStartIdentity: SystemIdentityResolver.processStartIdentity(ownerPID),
                       focusedWindowPID: focusedWindow.pid(),
                       frontmostPID: frontmostPID,
                       focusedWindowMatchesPreparedDialog: DialogService.sameElement(
                           focusedWindow,
                           attachedDialog.dialog),
                       preparedDialogIsStructural: DialogElementClassifier.isStructuralDialog(
                           DialogElementClassifier.evidence(for: attachedDialog.dialog)),
                       preparedDialogAttachedToParent: DialogService.rawElementPresence(
                           attachedDialog.dialog,
                           in: windowElement) == .present))
            {
                return
            }

            try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }

        throw FocusError.focusVerificationTimeout(windowID)
    }

    nonisolated static func isVerifiedFocus(
        targetWindowID: CGWindowID,
        ownerPID: pid_t,
        focusedWindowID: CGWindowID?,
        frontmostPID: pid_t?) -> Bool
    {
        focusedWindowID == targetWindowID && frontmostPID == ownerPID
    }

    nonisolated static func isVerifiedParentWindowFocus(
        targetWindowID: CGWindowID,
        ownerPID: pid_t,
        focusedWindowID: CGWindowID?,
        frontmostPID: pid_t?,
        hasAttachedDialog: Bool) -> Bool
    {
        !hasAttachedDialog && self.isVerifiedFocus(
            targetWindowID: targetWindowID,
            ownerPID: ownerPID,
            focusedWindowID: focusedWindowID,
            frontmostPID: frontmostPID)
    }

    nonisolated static func isVerifiedAttachedDialogFocus(
        expectedParent: WindowMutationIdentity,
        observation: AttachedDialogFocusObservation) -> Bool
    {
        observation.currentProcessStartIdentity == expectedParent.ownerProcessStartIdentity &&
            observation.focusedWindowPID == expectedParent.ownerProcessIdentifier &&
            observation.frontmostPID == expectedParent.ownerProcessIdentifier &&
            observation.focusedWindowMatchesPreparedDialog &&
            observation.preparedDialogIsStructural &&
            observation.preparedDialogAttachedToParent
    }

    nonisolated static func isVerifiedDialogDispatchFocus(
        expectedParent: WindowMutationIdentity,
        observation: DialogDispatchFocusObservation) -> Bool
    {
        observation.currentProcessStartIdentity == expectedParent.ownerProcessStartIdentity &&
            observation.focusedWindowPID == expectedParent.ownerProcessIdentifier &&
            observation.frontmostPID == expectedParent.ownerProcessIdentifier &&
            observation.retainedParentMatches &&
            observation.preparedDialogIsStructural &&
            observation.preparedDialogAttachedToParent &&
            observation.focusedElementPID == expectedParent.ownerProcessIdentifier &&
            observation.focusedElementMatchesRetainedField &&
            observation.retainedFieldAttachedToDialog &&
            (observation.focusedWindowID == expectedParent.windowID ||
                observation.focusedWindowMatchesPreparedDialog)
    }

    private func focusedWindow(for app: NSRunningApplication, timeout: TimeInterval) -> Element? {
        guard timeout > 0 else { return nil }
        let axApp = AXApp(app)
        return try? axApp.element.withMessagingTimeout(Float(timeout)) { _ in axApp.focusedWindow() }
    }

    private func focusedElement(for app: NSRunningApplication, timeout: TimeInterval) -> Element? {
        guard timeout > 0 else { return nil }
        let axApp = AXApp(app)
        return try? axApp.element.withMessagingTimeout(Float(timeout)) { $0.focusedUIElement() }
    }

    nonisolated static func processIdentifier(for element: AXUIElement) -> pid_t? {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success,
              processIdentifier > 0
        else {
            return nil
        }
        return processIdentifier
    }

    private func prioritizeWindows(_ windows: [WindowIdentityInfo]) -> [WindowIdentityInfo] {
        let renderable = windows.filter(\.isRenderable)
        if !renderable.isEmpty {
            return renderable
        }
        return windows
    }

    private func matchesWindow(_ window: WindowIdentityInfo, title: String) -> Bool {
        guard let windowTitle = window.title, !windowTitle.isEmpty else { return false }
        return windowTitle.localizedCaseInsensitiveContains(title)
    }

    private func waitForCondition(
        timeout: TimeInterval,
        interval: TimeInterval,
        condition: () -> Bool) async throws
    {
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }

        throw FocusError.timeoutWaitingForCondition
    }
}

// MARK: - Focus Errors

public enum FocusError: LocalizedError {
    case applicationNotRunning(String)
    case noWindowsFound(String)
    case windowNotFound(CGWindowID)
    case axElementNotFound(CGWindowID)
    case focusVerificationFailed(CGWindowID)
    case focusVerificationTimeout(CGWindowID)
    case timeoutWaitingForCondition

    public var errorDescription: String? {
        switch self {
        case let .applicationNotRunning(name):
            "Application '\(name)' is not running"
        case let .noWindowsFound(name):
            "No windows found for application '\(name)'"
        case let .windowNotFound(id):
            "Window with ID \(id) not found"
        case let .axElementNotFound(id):
            "Could not find accessibility element for window ID \(id)"
        case let .focusVerificationFailed(id):
            "Failed to verify focus for window ID \(id)"
        case let .focusVerificationTimeout(id):
            "Timeout while verifying focus for window ID \(id)"
        case .timeoutWaitingForCondition:
            "Timeout while waiting for condition"
        }
    }
}
