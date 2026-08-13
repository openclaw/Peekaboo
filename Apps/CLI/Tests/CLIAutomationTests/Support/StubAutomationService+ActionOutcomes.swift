import Foundation
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooFoundation

@MainActor
final class OutcomeStubAutomationService: StubAutomationService, ScriptedUIAutomationActionOutcomeProviding,
ExactWindowTargetedKeyboardServiceProtocol, TargetedFocusedElementServiceProtocol {
    struct ExactTypeActionsCall {
        let actions: [TypeAction]
        let target: ExactWindowKeyboardTarget
    }

    struct ExactHotkeyCall {
        let keys: String
        let target: ExactWindowKeyboardTarget
    }

    let uiAutomationOutcomeScript = UIAutomationOutcomeScript()
    let supportsExactWindowTargetedKeyboard = true
    let exactWindowTargetedKeyboardUnavailableReason: String? = nil
    var exactTypeActionsCalls: [ExactTypeActionsCall] = []
    var exactHotkeyCalls: [ExactHotkeyCall] = []
    var targetedFocusedElement: UIFocusInfo?

    var actionOutcome: DesktopActionOutcome? {
        didSet {
            self.uiAutomationOutcomeScript.setDefaultOutcome(self.actionOutcome)
        }
    }

    var outcomeHotkeyCallCount: Int {
        self.uiAutomationOutcomeScript.callCount(for: .hotkey)
    }

    func failHotkey(_ error: any Error, onCall call: Int) {
        precondition(call > 0, "A scripted hotkey failure requires a positive call index")
        for _ in 1..<call {
            self.uiAutomationOutcomeScript.append(self.actionOutcome, for: .hotkey)
        }
        self.uiAutomationOutcomeScript.appendFailure(error, for: .hotkey)
    }

    func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        target: ExactWindowKeyboardTarget
    ) async throws -> TypeResult {
        self.exactTypeActionsCalls.append(ExactTypeActionsCall(actions: actions, target: target))
        return try await super.typeActions(actions, cadence: cadence, snapshotId: snapshotId)
    }

    func hotkey(
        keys: String,
        holdDuration _: Int,
        target: ExactWindowKeyboardTarget
    ) async throws {
        self.exactHotkeyCalls.append(ExactHotkeyCall(keys: keys, target: target))
    }

    func getFocusedElement(targetProcessIdentifier: pid_t) async -> UIFocusInfo? {
        guard self.targetedFocusedElement?.processId == Int(targetProcessIdentifier) else { return nil }
        return self.targetedFocusedElement
    }
}
