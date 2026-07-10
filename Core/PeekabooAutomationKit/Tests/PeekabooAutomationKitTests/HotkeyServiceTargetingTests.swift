import AppKit
import CoreGraphics
import Darwin
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct HotkeyServiceTargetingTests {
    @Test func `targeted hotkey planner accepts one primary key with modifiers`() throws {
        let service = HotkeyService()

        let plan = try service.targetedHotkeyPlanForTesting(["command", "shift", "p"])

        #expect(plan.primaryKey == "p")
        #expect(plan.keyCode == 0x23)
        #expect(plan.flags.contains(.maskCommand))
        #expect(plan.flags.contains(.maskShift))
    }

    @Test func `targeted hotkey planner rejects modifier-only input`() throws {
        let service = HotkeyService()

        #expect(throws: PeekabooError.self) {
            _ = try service.targetedHotkeyPlanForTesting(["cmd", "shift"])
        }
    }

    @Test func `targeted hotkey planner rejects multiple primary keys`() throws {
        let service = HotkeyService()

        #expect(throws: PeekabooError.self) {
            _ = try service.targetedHotkeyPlanForTesting(["cmd", "k", "c"])
        }
    }

    @Test func `targeted hotkey planner accepts foreground modifier aliases`() throws {
        let service = HotkeyService()

        let plan = try service.targetedHotkeyPlanForTesting(["function", "f1"])

        #expect(plan.primaryKey == "f1")
        #expect(plan.keyCode == 0x7A)
        #expect(plan.flags.contains(.maskSecondaryFn))
    }

    @Test func `targeted hotkey planner accepts AXorcist key aliases`() throws {
        let service = HotkeyService()

        let targetedPlan = try service.targetedHotkeyPlanForTesting(["cmd", "arrow_up"])

        #expect(targetedPlan.primaryKey == "up")
        #expect(targetedPlan.keyCode == 0x7E)
        #expect(targetedPlan.flags.contains(.maskCommand))
    }

    @Test func `targeted hotkey planner accepts documented punctuation key names`() throws {
        let service = HotkeyService()

        let commaPlan = try service.targetedHotkeyPlanForTesting(["cmd", "comma"])
        let slashPlan = try service.targetedHotkeyPlanForTesting(["cmd", "slash"])

        #expect(commaPlan.primaryKey == "comma")
        #expect(commaPlan.keyCode == 0x2B)
        #expect(slashPlan.primaryKey == "slash")
        #expect(slashPlan.keyCode == 0x2C)
    }

    @Test func `targeted hotkey planner normalizes foreground key aliases`() throws {
        let service = HotkeyService()

        let returnPlan = try service.targetedHotkeyPlanForTesting(["enter"])
        let deletePlan = try service.targetedHotkeyPlanForTesting(["backspace"])
        let delPlan = try service.targetedHotkeyPlanForTesting(["del"])

        #expect(returnPlan.primaryKey == "return")
        #expect(returnPlan.keyCode == 0x24)
        #expect(deletePlan.primaryKey == "delete")
        #expect(deletePlan.keyCode == 0x33)
        #expect(delPlan.primaryKey == "delete")
        #expect(delPlan.keyCode == 0x33)
    }

    @Test func `background text insertion replaces selected UTF16 range`() {
        let edit = BackgroundInputDriver.textByReplacingSelection(
            in: "prefix suffix",
            selection: CFRange(location: 7, length: 6),
            replacement: "value")

        #expect(edit.text == "prefix value")
        #expect(edit.cursorLocation == 12)
    }

    @Test func `background text insertion handles emoji UTF16 offsets`() {
        let edit = BackgroundInputDriver.textByReplacingSelection(
            in: "a😀c",
            selection: CFRange(location: 1, length: 2),
            replacement: "b")

        #expect(edit.text == "abc")
        #expect(edit.cursorLocation == 2)
    }

    @Test func `background text insertion appends when selection is unavailable`() {
        let edit = BackgroundInputDriver.textByReplacingSelection(
            in: "base",
            selection: nil,
            replacement: " tail")

        #expect(edit.text == "base tail")
        #expect(edit.cursorLocation == 9)
    }

    @Test func `background text cursor movement respects UTF16 character boundaries`() {
        let text = "a😀c"

        #expect(BackgroundInputDriver.cursorLocationMovingLeft(
            from: CFRange(location: 3, length: 0),
            in: text) == 1)
        #expect(BackgroundInputDriver.cursorLocationMovingRight(
            from: CFRange(location: 1, length: 0),
            in: text) == 3)
        #expect(BackgroundInputDriver.cursorLocationMovingLeft(
            from: CFRange(location: 1, length: 2),
            in: text) == 1)
        #expect(BackgroundInputDriver.cursorLocationMovingRight(
            from: CFRange(location: 1, length: 2),
            in: text) == 3)
    }

    @Test func `foreground hotkey parser trims and normalizes aliases before AXorcist delivery`() throws {
        let service = HotkeyService()

        let keys = try service.parsedKeysForTesting(" meta, SPACEBAR , backspace, cmdOrCtrl, del ")

        #expect(keys == ["cmd", "space", "delete", "cmd", "delete"])
    }

    @Test func `hold duration conversion rejects overflow before posting events`() throws {
        #expect(throws: PeekabooError.self) {
            _ = try HotkeyService.holdNanosecondsForTesting(Int.max)
        }
    }

    @Test func `targeted hotkey reports event synthesizing permission failures`() async throws {
        let service = HotkeyService(postEventAccessEvaluator: { false })

        do {
            try await service.hotkey(
                keys: "cmd,l",
                holdDuration: 50,
                targetProcessIdentifier: getpid())
            Issue.record("Expected event-synthesizing permission error")
        } catch PeekabooError.permissionDeniedEventSynthesizing {
            // Expected.
        } catch {
            Issue.record("Expected event-synthesizing permission error, got \(error)")
        }
    }

    @Test func `targeted hotkey posts key down and key up to target process`() async throws {
        var postedEvents: [PostedKeyboardEvent] = []
        let service = HotkeyService(
            postEventAccessEvaluator: { true },
            eventPoster: { event, pid in
                postedEvents.append(PostedKeyboardEvent(
                    type: event.type,
                    keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                    flags: event.flags,
                    targetPID: event.getIntegerValueField(.eventTargetUnixProcessID),
                    pid: pid))
            })

        try await service.hotkey(keys: "cmd,shift,l", holdDuration: 0, targetProcessIdentifier: getpid())

        #expect(postedEvents.count == 6)
        #expect(postedEvents.map(\.type) == [
            .flagsChanged,
            .flagsChanged,
            .keyDown,
            .keyUp,
            .flagsChanged,
            .flagsChanged,
        ])
        #expect(postedEvents.map(\.keyCode) == [0x37, 0x38, 0x25, 0x25, 0x38, 0x37])
        #expect(postedEvents[0].flags.contains(.maskCommand))
        #expect(postedEvents[1].flags.contains(.maskCommand) && postedEvents[1].flags.contains(.maskShift))
        #expect(postedEvents[2].flags.contains(.maskCommand) && postedEvents[2].flags.contains(.maskShift))
        #expect(postedEvents[3].flags.contains(.maskCommand) && postedEvents[3].flags.contains(.maskShift))
        #expect(postedEvents[4].flags.contains(.maskCommand) && !postedEvents[4].flags.contains(.maskShift))
        #expect(!postedEvents[5].flags.contains(.maskCommand) && !postedEvents[5].flags.contains(.maskShift))
        #expect(postedEvents.allSatisfy { $0.targetPID == Int64(getpid()) })
        #expect(postedEvents.allSatisfy { $0.pid == getpid() })
    }

    @Test func `process liveness check rejects stale pids`() {
        #expect(HotkeyService.isProcessAliveForTesting(getpid()))
        #expect(!HotkeyService.isProcessAliveForTesting(pid_t(Int32.max)))
    }

    @Test func `action first targeted hotkey uses action driver when menu shortcut resolves`() async throws {
        var postedEvents: [(type: CGEventType, keyCode: Int64)] = []
        let driver = RecordingHotkeyActionDriver(result: ActionInputResult(actionName: "AXPress"))
        let service = HotkeyService(
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            actionInputDriver: driver,
            postEventAccessEvaluator: { true },
            eventPoster: { event, _ in
                postedEvents.append((event.type, event.getIntegerValueField(.keyboardEventKeycode)))
            },
            runningApplicationResolver: { _ in NSRunningApplication.current })

        try await service.hotkey(keys: "cmd,s", holdDuration: 0, targetProcessIdentifier: getpid())

        #expect(driver.hotkeyCalls == [["cmd", "s"]])
        #expect(postedEvents.isEmpty)
    }

    @Test func `action first targeted hotkey falls back to synth when menu shortcut is unavailable`() async throws {
        var postedEvents: [(type: CGEventType, keyCode: Int64)] = []
        let driver = RecordingHotkeyActionDriver(error: .unsupported(.menuShortcutUnavailable))
        let service = HotkeyService(
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            actionInputDriver: driver,
            postEventAccessEvaluator: { true },
            eventPoster: { event, _ in
                postedEvents.append((event.type, event.getIntegerValueField(.keyboardEventKeycode)))
            },
            runningApplicationResolver: { _ in NSRunningApplication.current })

        try await service.hotkey(keys: "cmd,s", holdDuration: 0, targetProcessIdentifier: getpid())

        #expect(driver.hotkeyCalls == [["cmd", "s"]])
        #expect(postedEvents.map(\.type) == [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        #expect(postedEvents.map(\.keyCode) == [0x37, 0x01, 0x01, 0x37])
    }
}

private struct PostedKeyboardEvent {
    let type: CGEventType
    let keyCode: Int64
    let flags: CGEventFlags
    let targetPID: Int64
    let pid: pid_t
}

@MainActor
private final class RecordingHotkeyActionDriver: ActionInputDriving {
    private let result: ActionInputResult?
    private let error: ActionInputError?
    private(set) var hotkeyCalls: [[String]] = []

    init(result: ActionInputResult? = nil, error: ActionInputError? = nil) {
        self.result = result
        self.error = error
    }

    func tryClick(element _: AutomationElement) throws -> ActionInputResult {
        throw ActionInputError.unsupported(.actionUnsupported)
    }

    func tryRightClick(element _: any AutomationElementRepresenting) async throws -> ActionInputResult {
        throw ActionInputError.unsupported(.actionUnsupported)
    }

    func tryScroll(
        element _: AutomationElement,
        direction _: ScrollDirection,
        pages _: Int) throws -> ActionInputResult
    {
        throw ActionInputError.unsupported(.actionUnsupported)
    }

    func trySetText(element _: AutomationElement, text _: String, replace _: Bool) throws -> ActionInputResult {
        throw ActionInputError.unsupported(.attributeUnsupported)
    }

    func tryHotkey(application _: NSRunningApplication, keys: [String]) throws -> ActionInputResult {
        self.hotkeyCalls.append(keys)
        if let error {
            throw error
        }
        return self.result ?? ActionInputResult(actionName: "AXPress")
    }

    func trySetValue(element _: AutomationElement, value _: UIElementValue) throws -> ActionInputResult {
        throw ActionInputError.unsupported(.valueNotSettable)
    }

    func tryPerformAction(element _: AutomationElement, actionName _: String) throws -> ActionInputResult {
        throw ActionInputError.unsupported(.actionUnsupported)
    }
}
