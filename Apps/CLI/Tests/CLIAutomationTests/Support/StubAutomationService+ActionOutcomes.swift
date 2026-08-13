import PeekabooAutomationKitTestSupport
import PeekabooFoundation

@MainActor
final class OutcomeStubAutomationService: StubAutomationService, ScriptedUIAutomationActionOutcomeProviding {
    let uiAutomationOutcomeScript = UIAutomationOutcomeScript()

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
}
