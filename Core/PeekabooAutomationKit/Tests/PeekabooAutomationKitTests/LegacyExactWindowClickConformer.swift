import CoreGraphics
import Darwin
import PeekabooAutomationKit
import PeekabooFoundation

/// Uses public imports and only the released exact-click witnesses, like an existing external provider.
/// Unrelated base operations inherit the test suite's fail-on-use implementation.
@MainActor
final class LegacyExactWindowClickConformer:
    UnusedUIAutomationService,
    ExactWindowTargetedClickServiceProtocol,
    UIAutomationActionOutcomeProviding
{
    struct Call {
        let target: ClickTarget
        let clickType: ClickType
        let snapshotID: String?
        let identity: WindowMutationIdentity
        let bounds: CGRect
    }

    private(set) var clickCalls: [Call] = []
    private(set) var outcomeCalls: [Call] = []
    let result = UIAutomationActionResult(
        payload: (),
        outcome: DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one))

    func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws
    {
        self.clickCalls.append(Call(
            target: target,
            clickType: clickType,
            snapshotID: snapshotId,
            identity: expectedWindowIdentity,
            bounds: expectedWindowBounds))
    }

    func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> UIAutomationActionResult<Void>
    {
        self.outcomeCalls.append(Call(
            target: target,
            clickType: clickType,
            snapshotID: snapshotId,
            identity: expectedWindowIdentity,
            bounds: expectedWindowBounds))
        return self.result
    }
}

extension LegacyExactWindowClickConformer {
    private enum UnexpectedOperation: Error {
        case called
    }

    func click(
        target _: ClickTarget,
        clickType _: ClickType,
        snapshotId _: String?,
        targetProcessIdentifier _: pid_t) async throws
    {
        throw UnexpectedOperation.called
    }

    func clickWithOutcome(
        target _: ClickTarget,
        clickType _: ClickType,
        snapshotId _: String?) async throws -> UIAutomationActionResult<Void>
    {
        throw UnexpectedOperation.called
    }

    func clickWithOutcome(
        target _: ClickTarget,
        clickType _: ClickType,
        snapshotId _: String?,
        targetProcessIdentifier _: pid_t) async throws -> UIAutomationActionResult<Void>
    {
        throw UnexpectedOperation.called
    }

    func clickWithOutcome(
        target _: ClickTarget,
        clickType _: ClickType,
        snapshotId _: String?,
        expectedProcessIdentity _: ApplicationProcessIdentity) async throws -> UIAutomationActionResult<Void>
    {
        throw UnexpectedOperation.called
    }

    func typeWithOutcome(
        text _: String,
        target _: String?,
        clearExisting _: Bool,
        typingDelay _: Int,
        snapshotId _: String?) async throws -> UIAutomationActionResult<Void>
    {
        throw UnexpectedOperation.called
    }

    func typeActionsWithOutcome(
        _: [TypeAction],
        cadence _: TypingCadence,
        snapshotId _: String?) async throws -> UIAutomationActionResult<TypeResult>
    {
        throw UnexpectedOperation.called
    }

    func typeActionsWithOutcome(
        _: [TypeAction],
        cadence _: TypingCadence,
        snapshotId _: String?,
        targetProcessIdentifier _: pid_t) async throws -> UIAutomationActionResult<TypeResult>
    {
        throw UnexpectedOperation.called
    }

    func typeActionsWithOutcome(
        _: [TypeAction],
        cadence _: TypingCadence,
        snapshotId _: String?,
        expectedProcessIdentity _: ApplicationProcessIdentity) async throws -> UIAutomationActionResult<TypeResult>
    {
        throw UnexpectedOperation.called
    }

    func typeActionsWithOutcome(
        _: [TypeAction],
        cadence _: TypingCadence,
        snapshotId _: String?,
        expectedWindowIdentity _: WindowMutationIdentity,
        expectedWindowBounds _: CGRect) async throws -> UIAutomationActionResult<TypeResult>
    {
        throw UnexpectedOperation.called
    }

    func typeActionsWithOutcome(
        _: [TypeAction],
        cadence _: TypingCadence,
        snapshotId _: String?,
        target _: ExactWindowKeyboardTarget) async throws -> UIAutomationActionResult<TypeResult>
    {
        throw UnexpectedOperation.called
    }

    func scrollWithOutcome(_: ScrollRequest) async throws -> UIAutomationActionResult<Void> {
        throw UnexpectedOperation.called
    }

    func hotkeyWithOutcome(keys _: String, holdDuration _: Int) async throws -> UIAutomationActionResult<Void> {
        throw UnexpectedOperation.called
    }

    func hotkeyWithOutcome(
        keys _: String,
        holdDuration _: Int,
        targetProcessIdentifier _: pid_t) async throws -> UIAutomationActionResult<Void>
    {
        throw UnexpectedOperation.called
    }

    func hotkeyWithOutcome(
        keys _: String,
        holdDuration _: Int,
        expectedProcessIdentity _: ApplicationProcessIdentity) async throws -> UIAutomationActionResult<Void>
    {
        throw UnexpectedOperation.called
    }

    func hotkeyWithOutcome(
        keys _: String,
        holdDuration _: Int,
        expectedWindowIdentity _: WindowMutationIdentity,
        expectedWindowBounds _: CGRect) async throws -> UIAutomationActionResult<Void>
    {
        throw UnexpectedOperation.called
    }

    func hotkeyWithOutcome(
        keys _: String,
        holdDuration _: Int,
        target _: ExactWindowKeyboardTarget) async throws -> UIAutomationActionResult<Void>
    {
        throw UnexpectedOperation.called
    }

    func setValueWithOutcome(
        target _: String,
        value _: UIElementValue,
        snapshotId _: String?) async throws -> UIAutomationActionResult<ElementActionResult>
    {
        throw UnexpectedOperation.called
    }

    func performActionWithOutcome(
        target _: String,
        actionName _: String,
        snapshotId _: String?) async throws -> UIAutomationActionResult<ElementActionResult>
    {
        throw UnexpectedOperation.called
    }
}
