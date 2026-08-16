import AppKit
import CoreGraphics
import Darwin
import os
import PeekabooAutomationKitTestSupport
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

    @Test func `generation pinned hotkey validates its receipt without an external validator`() async throws {
        var postedEventCount = 0
        let service = HotkeyService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            postEventAccessEvaluator: { true },
            eventPoster: { _, _ in postedEventCount += 1 },
            processStartIdentityProvider: { _ in 12 })

        await #expect(throws: PeekabooError.self) {
            try await service.hotkey(
                keys: "cmd,l",
                holdDuration: 0,
                targetProcessIdentifier: getpid(),
                expectedProcessIdentity: ApplicationProcessIdentity(
                    processIdentifier: getpid(),
                    processStartIdentity: 11))
        }
        #expect(postedEventCount == 0)
    }

    @Test func `targeted lifecycle hotkeys fail before posting unverifiable events`() async throws {
        var postedEventCount = 0
        let service = HotkeyService(
            postEventAccessEvaluator: { true },
            eventPoster: { _, _ in postedEventCount += 1 })
        let cases = [
            (keys: "command+w", chord: "Cmd+W", alternative: "peekaboo window close"),
            (keys: "CMD,Q", chord: "Cmd+Q", alternative: "peekaboo app quit"),
            (keys: "cmd h", chord: "Cmd+H", alternative: "peekaboo app hide"),
            (keys: "cmd,m", chord: "Cmd+M", alternative: "peekaboo window minimize"),
        ]

        for testCase in cases {
            do {
                try await service.hotkey(
                    keys: testCase.keys,
                    holdDuration: 0,
                    targetProcessIdentifier: getpid())
                Issue.record("Expected background \(testCase.chord) to fail closed")
            } catch {
                #expect(error.localizedDescription.contains(testCase.chord))
                #expect(error.localizedDescription.contains(testCase.alternative))
                #expect(error.localizedDescription.contains("--foreground"))
            }
        }

        #expect(postedEventCount == 0)
    }

    @Test func `targeted policy does not mistake modified app shortcuts for lifecycle commands`() async throws {
        var postedEvents: [CGEventType] = []
        let service = HotkeyService(
            postEventAccessEvaluator: { true },
            eventPoster: { event, _ in postedEvents.append(event.type) })

        try await service.hotkey(
            keys: "cmd,shift,h",
            holdDuration: 0,
            targetProcessIdentifier: getpid())

        #expect(postedEvents == [.flagsChanged, .flagsChanged, .keyDown, .keyUp, .flagsChanged, .flagsChanged])
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

    @Test func `exact window held hotkey reports cleanup units`() async throws {
        var postedEvents: [CGEventType] = []
        let identity = ApplicationProcessIdentity(
            processIdentifier: getpid(),
            processStartIdentity: 700)
        let service = HotkeyService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            postEventAccessEvaluator: { true },
            eventPoster: { event, _ in postedEvents.append(event.type) },
            processStartIdentityProvider: { _ in 700 },
            holdSleeper: { _ in })
        let target = try UIAutomationTarget.exactWindow(.init(
            identity: WindowMutationIdentity(
                windowID: 42,
                ownerProcessIdentifier: identity.processIdentifier,
                ownerProcessStartIdentity: identity.processStartIdentity),
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100)))

        let result = try await service.hotkey(
            keys: "cmd,l",
            holdDuration: 50,
            automationTarget: target)

        #expect(postedEvents == [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        #expect(result.outcome.dispatchState.unitCount?.rawValue == 4)
        #expect(result.outcome.delivery == .init(mechanism: .windowTargetedEvents, mode: .background))
    }

    @Test func `cancelling exact window hold releases only to original generation and counts cleanup`() async throws {
        var postedEvents: [CGEventType] = []
        let target = try self.heldHotkeyTarget(generation: 701)
        let service = HotkeyService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            postEventAccessEvaluator: { true },
            eventPoster: { event, _ in postedEvents.append(event.type) },
            processStartIdentityProvider: { _ in 701 },
            holdSleeper: { _ in try await Task.sleep(for: .seconds(30)) })
        let task = Task { @MainActor in
            try await service.hotkey(
                keys: "cmd,l",
                holdDuration: 30000,
                automationTarget: target)
        }
        while postedEvents.count < 2 {
            await Task.yield()
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected held hotkey cancellation to be retry-unsafe")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.emittedUnitCount == 4)
            #expect(error.causeDescription?.contains("released to the original process generation") == true)
        }
        #expect(postedEvents == [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
    }

    @Test func `recycled PID receives no held hotkey cleanup`() async throws {
        var postedEvents: [CGEventType] = []
        let generation = OSAllocatedUnfairLock<UInt64?>(initialState: 702)
        let target = try self.heldHotkeyTarget(generation: 702)
        let service = HotkeyService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            postEventAccessEvaluator: { true },
            eventPoster: { event, _ in
                postedEvents.append(event.type)
                if event.type == .keyDown {
                    generation.withLock { $0 = 703 }
                }
            },
            processStartIdentityProvider: { _ in generation.withLock { $0 } },
            holdSleeper: { _ in throw CancellationError() })

        do {
            _ = try await service.hotkey(
                keys: "cmd,l",
                holdDuration: 50,
                automationTarget: target)
            Issue.record("Expected recycled PID cleanup refusal")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.emittedUnitCount == 2)
            #expect(error.causeDescription?.contains("recycled PID") == true)
        }
        #expect(postedEvents == [.flagsChanged, .keyDown])
    }

    @Test func `PID recycle between held modifier downs blocks later modifier and cleanup`() async throws {
        var delayCount = 0
        var postedEvents: [(type: CGEventType, keyCode: Int64)] = []
        let generation = OSAllocatedUnfairLock<UInt64?>(initialState: 706)
        let target = try self.heldHotkeyTarget(generation: 706)
        let service = HotkeyService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            postEventAccessEvaluator: { true },
            eventPoster: { event, _ in
                postedEvents.append((
                    event.type,
                    event.getIntegerValueField(.keyboardEventKeycode)))
            },
            processStartIdentityProvider: { _ in generation.withLock { $0 } },
            holdSleeper: { _ in },
            heldInterEventDelay: {
                delayCount += 1
                if delayCount == 1 {
                    generation.withLock { $0 = 707 }
                }
            })

        do {
            _ = try await service.hotkey(
                keys: "cmd,shift,l",
                holdDuration: 50,
                automationTarget: target)
            Issue.record("Expected modifier-down generation drift")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.emittedUnitCount == 1)
            #expect(error.causeDescription?.contains("recycled PID") == true)
        }

        #expect(postedEvents.map(\.type) == [.flagsChanged])
        #expect(postedEvents.map(\.keyCode) == [0x37])
    }

    @Test func `PID recycle during held release delay blocks modifier release`() async throws {
        var delayCount = 0
        var postedEvents: [(type: CGEventType, keyCode: Int64)] = []
        let generation = OSAllocatedUnfairLock<UInt64?>(initialState: 708)
        let target = try self.heldHotkeyTarget(generation: 708)
        let service = HotkeyService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            postEventAccessEvaluator: { true },
            eventPoster: { event, _ in
                postedEvents.append((
                    event.type,
                    event.getIntegerValueField(.keyboardEventKeycode)))
            },
            processStartIdentityProvider: { _ in generation.withLock { $0 } },
            holdSleeper: { _ in },
            heldInterEventDelay: {
                delayCount += 1
                if delayCount == 3 {
                    generation.withLock { $0 = 709 }
                }
            })

        do {
            _ = try await service.hotkey(
                keys: "cmd,shift,l",
                holdDuration: 50,
                automationTarget: target)
            Issue.record("Expected modifier-release generation drift")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.emittedUnitCount == 4)
            #expect(error.causeDescription?.contains("recycled PID") == true)
        }

        #expect(postedEvents.map(\.type) == [.flagsChanged, .flagsChanged, .keyDown, .keyUp])
        #expect(postedEvents.map(\.keyCode) == [0x37, 0x38, 0x25, 0x25])
    }

    @Test func `generation drift during cleanup counts completed key up and stops modifier cleanup`() async throws {
        var postedEvents: [CGEventType] = []
        let generation = OSAllocatedUnfairLock<UInt64?>(initialState: 704)
        let target = try self.heldHotkeyTarget(generation: 704)
        let service = HotkeyService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            postEventAccessEvaluator: { true },
            eventPoster: { event, _ in
                postedEvents.append(event.type)
                if event.type == .keyUp {
                    generation.withLock { $0 = 705 }
                }
            },
            processStartIdentityProvider: { _ in generation.withLock { $0 } },
            holdSleeper: { _ in })

        do {
            _ = try await service.hotkey(
                keys: "cmd,l",
                holdDuration: 50,
                automationTarget: target)
            Issue.record("Expected cleanup generation drift")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.emittedUnitCount == 3)
        }
        #expect(postedEvents == [.flagsChanged, .keyDown, .keyUp])
    }

    @Test func `exact window validator failure before modifiers posts no events`() async throws {
        var validationCount = 0
        var postedEventCount = 0
        let service = HotkeyService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            postEventAccessEvaluator: { true },
            eventPoster: { _, _ in postedEventCount += 1 })

        do {
            try await service.hotkey(
                keys: "cmd,shift,l",
                holdDuration: 0,
                targetProcessIdentifier: getpid(),
                deliveryValidator: {
                    validationCount += 1
                    if validationCount == 2 {
                        throw HotkeyDeliveryTestError.focusChanged
                    }
                })
            Issue.record("Expected exact-window validation to fail")
        } catch HotkeyDeliveryTestError.focusChanged {
            // Expected.
        } catch {
            Issue.record("Expected focus-changed error, got \(error)")
        }

        #expect(validationCount == 2)
        #expect(postedEventCount == 0)
    }

    @Test func `exact window focus change blocks primary hotkey event`() async {
        let events = await self.targetedFocusChangeEvents()
        let primaryEvents = events.filter { event in
            event.type == .keyDown || event.type == .keyUp
        }

        #expect(primaryEvents.isEmpty)
    }

    @Test func `exact window focus change releases every pressed modifier`() async {
        let events = await self.targetedFocusChangeEvents()

        #expect(events.map(\.type) == [.flagsChanged, .flagsChanged, .flagsChanged, .flagsChanged])
        #expect(events.map(\.keyCode) == [0x37, 0x38, 0x38, 0x37])
    }

    @Test func `final hotkey drift is retry unsafe after all releases`() async throws {
        var destinationIsValid = true
        var validationCount = 0
        var postedEvents: [CGEventType] = []
        let service = HotkeyService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            postEventAccessEvaluator: { true },
            eventPoster: { event, _ in
                postedEvents.append(event.type)
                if postedEvents.count == 6 {
                    destinationIsValid = false
                }
            })

        do {
            try await service.hotkey(
                keys: "cmd,shift,l",
                holdDuration: 0,
                targetProcessIdentifier: getpid(),
                deliveryValidator: {
                    validationCount += 1
                    guard destinationIsValid else {
                        throw HotkeyDeliveryTestError.focusChanged
                    }
                })
            Issue.record("Expected final hotkey validation to fail")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.operation == .hotkey)
            #expect(error.emittedUnitCount == 6)
            #expect(error.operationMayHaveCompleted)
            #expect(!error.retrySafe)
            #expect(error.causeDescription?.contains("focus changed") == true)
        } catch {
            Issue.record("Expected indeterminate delivery error, got \(error)")
        }

        #expect(validationCount == 4)
        #expect(postedEvents == [
            .flagsChanged,
            .flagsChanged,
            .keyDown,
            .keyUp,
            .flagsChanged,
            .flagsChanged,
        ])
    }

    @Test func `process liveness check rejects stale pids`() {
        #expect(HotkeyService.isProcessAliveForTesting(getpid()))
        #expect(!HotkeyService.isProcessAliveForTesting(pid_t(Int32.max)))
    }

    @Test func `action first targeted hotkey uses action driver when menu shortcut resolves`() async throws {
        var postedEvents: [(type: CGEventType, keyCode: Int64)] = []
        let driver = RecordingHotkeyActionDriver(
            result: AutomationTestFixtures.uiActionReceipt(actionName: "AXPress"))
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

    private func targetedFocusChangeEvents() async -> [PostedKeyboardEvent] {
        var exactWindowHasFocus = true
        var postedEvents: [PostedKeyboardEvent] = []
        let service = HotkeyService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            postEventAccessEvaluator: { true },
            eventPoster: { event, pid in
                postedEvents.append(PostedKeyboardEvent(
                    type: event.type,
                    keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                    flags: event.flags,
                    targetPID: event.getIntegerValueField(.eventTargetUnixProcessID),
                    pid: pid))
                if postedEvents.count == 2 {
                    exactWindowHasFocus = false
                }
            })

        do {
            try await service.hotkey(
                keys: "cmd,shift,l",
                holdDuration: 0,
                targetProcessIdentifier: getpid(),
                deliveryValidator: {
                    guard exactWindowHasFocus else {
                        throw HotkeyDeliveryTestError.focusChanged
                    }
                })
            Issue.record("Expected focus change to stop hotkey delivery")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.operation == .hotkey)
            #expect(error.emittedUnitCount == 2)
            #expect(error.operationMayHaveCompleted)
            #expect(!error.retrySafe)
            #expect(error.causeDescription?.contains("focus changed") == true)
        } catch {
            Issue.record("Expected indeterminate delivery error, got \(error)")
        }

        return postedEvents
    }
}

extension HotkeyServiceTargetingTests {
    private func heldHotkeyTarget(generation: UInt64) throws -> UIAutomationTarget {
        try .exactWindow(.init(
            identity: WindowMutationIdentity(
                windowID: 42,
                ownerProcessIdentifier: getpid(),
                ownerProcessStartIdentity: generation),
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100)))
    }
}

private enum HotkeyDeliveryTestError: LocalizedError {
    case focusChanged

    var errorDescription: String? {
        "focus changed"
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
    private let result: UIInputExecutionResult.Action?
    private let error: ActionInputError?
    private(set) var hotkeyCalls: [[String]] = []

    init(result: UIInputExecutionResult.Action? = nil, error: ActionInputError? = nil) {
        self.result = result
        self.error = error
    }

    func tryClick(element _: AutomationElement) throws -> UIInputExecutionResult.Action {
        throw ActionInputError.unsupported(.actionUnsupported)
    }

    func tryRightClick(element _: any AutomationElementRepresenting) async throws
        -> UIInputExecutionResult.Action
    {
        throw ActionInputError.unsupported(.actionUnsupported)
    }

    func tryScroll(
        element _: AutomationElement,
        direction _: ScrollDirection,
        pages _: Int) throws -> UIInputExecutionResult.Action
    {
        throw ActionInputError.unsupported(.actionUnsupported)
    }

    func trySetText(element _: AutomationElement, text _: String, replace _: Bool) throws
        -> UIInputExecutionResult.Action
    {
        throw ActionInputError.unsupported(.attributeUnsupported)
    }

    func tryHotkey(application _: NSRunningApplication, keys: [String]) throws
        -> UIInputExecutionResult.Action
    {
        self.hotkeyCalls.append(keys)
        if let error {
            throw error
        }
        return self.result ?? AutomationTestFixtures.uiActionReceipt(actionName: "AXPress")
    }

    func trySetValue(element _: AutomationElement, value _: UIElementValue) throws
        -> UIInputExecutionResult.Action
    {
        throw ActionInputError.unsupported(.valueNotSettable)
    }

    func tryPerformAction(element _: AutomationElement, actionName _: String) throws
        -> UIInputExecutionResult.Action
    {
        throw ActionInputError.unsupported(.actionUnsupported)
    }
}
