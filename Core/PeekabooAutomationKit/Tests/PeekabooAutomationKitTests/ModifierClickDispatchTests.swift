import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct ModifierClickDispatchTests {
    @Test
    func `shared input token tracks held keys and buttons without persistent toggle flags`() {
        let released = SharedInputActivityToken.current(
            keyStateProvider: { _ in false },
            buttonStateProvider: { _ in false })
        let heldKey = SharedInputActivityToken.current(
            keyStateProvider: { $0 == 4 },
            buttonStateProvider: { _ in false })
        let heldButton = SharedInputActivityToken.current(
            keyStateProvider: { _ in false },
            buttonStateProvider: { $0 == .left })
        let capsLockEnabled = SharedInputActivityToken.current(
            keyStateProvider: { $0 == 0x39 },
            buttonStateProvider: { _ in false })
        var queriedButtonValues: Set<UInt32> = []
        let heldAuxiliaryButton = SharedInputActivityToken.current(
            keyStateProvider: { _ in false },
            buttonStateProvider: {
                queriedButtonValues.insert($0.rawValue)
                return $0.rawValue == 3
            })

        #expect(!released.hasHeldInput)
        #expect(heldKey.hasHeldInput)
        #expect(heldButton.hasHeldInput)
        #expect(!capsLockEnabled.hasHeldInput)
        #expect(capsLockEnabled.afterModifierFlagsChange() != capsLockEnabled)
        #expect(heldAuxiliaryButton.hasHeldInput)
        #expect(queriedButtonValues == Set(UInt32(0)..<UInt32(32)))
        #expect(heldKey.afterMouseMove().hasHeldInput)
        #expect(heldButton.afterModifierClick(.single).hasHeldInput)
    }

    @Test
    func `modifier click prebuilds balanced modifier keys around the mouse sequence`() throws {
        let priorFlags = CGEventSource.flagsState(.combinedSessionState)
        let events = try UIAutomationService.makeModifierClickEvents(
            point: CGPoint(x: 220, y: 240),
            clickType: .double,
            modifiers: [.command, .shift, .option],
            source: CGEventSource(stateID: .hidSystemState),
            eventSourceUserData: 42)

        #expect(events.map(\.type) == [
            .flagsChanged, .flagsChanged, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp,
            .flagsChanged, .flagsChanged, .flagsChanged,
        ])
        #expect(events.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [
            0x37, 0x38, 0x3A, 0, 0, 0, 0, 0x3A, 0x38, 0x37,
        ])
        #expect(events.map { $0.getIntegerValueField(.mouseEventClickState) } == [
            0, 0, 0, 1, 1, 2, 2, 0, 0, 0,
        ])
        #expect(events.map(\.flags) == [
            [.maskCommand],
            [.maskCommand, .maskShift],
            [.maskCommand, .maskShift, .maskAlternate],
            [.maskCommand, .maskShift, .maskAlternate],
            [.maskCommand, .maskShift, .maskAlternate],
            [.maskCommand, .maskShift, .maskAlternate],
            [.maskCommand, .maskShift, .maskAlternate],
            [.maskCommand, .maskShift],
            [.maskCommand],
            [],
        ])
        #expect(events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == 42 })
        #expect(CGEventSource.flagsState(.combinedSessionState) == priorFlags)
    }

    @Test
    func `modifier click event preparation refuses control`() {
        #expect(throws: PeekabooError.self) {
            _ = try UIAutomationService.makeModifierClickEvents(
                point: CGPoint(x: 220, y: 240),
                clickType: .single,
                modifiers: [.control],
                source: CGEventSource(stateID: .hidSystemState))
        }
    }

    @Test
    func `shared input token accounts balanced modifier and mouse events`() {
        let baseline = SharedInputActivityToken.trackedZero
        let completed = baseline.afterModifierClick(
            .double,
            modifiers: [.command, .shift, .option])

        #expect(completed.leftDown == 2)
        #expect(completed.leftUp == 2)
        #expect(completed.keyDown == 0)
        #expect(completed.keyUp == 0)
        #expect(completed.flagsChanged == 6)
        #expect(!completed.hasHeldInput)
        #expect(completed != baseline.afterModifierClick(.double))
        #expect(completed.afterKeyboardInput() != completed)
    }

    @Test
    func `private event sources expose distinct counter state tables`() throws {
        let first = try #require(CGEventSource(stateID: .privateState))
        let second = try #require(CGEventSource(stateID: .privateState))

        #expect(first.sourceStateID != .privateState)
        #expect(second.sourceStateID != .privateState)
        #expect(first.sourceStateID != second.sourceStateID)
    }

    @Test
    func `private source barrier waits for mouse and modifier key ups`() throws {
        let clock = ContinuousClock()
        var now = clock.now
        let deadline = now.advanced(by: .milliseconds(3))
        var counters = ModifierClickDispatchBarrier.Counters(mouseUp: 7, modifierTransitions: 11)
        var steps = 0

        try ModifierClickDispatchBarrier.waitForCompletion(
            baseline: .init(mouseUp: 7, modifierTransitions: 11),
            expectedIncrement: .init(mouseUp: 2, modifierTransitions: 2),
            deadline: deadline,
            now: { now },
            counters: { counters },
            runLoopStep: {
                steps += 1
                counters = .init(
                    mouseUp: counters.mouseUp + 1,
                    modifierTransitions: counters.modifierTransitions + 1)
                now = now.advanced(by: .milliseconds(1))
            })

        #expect(steps == 2)
        #expect(counters == .init(mouseUp: 9, modifierTransitions: 13))
    }

    @Test
    func `modifier key up barrier timeout is cleanup unsafe and accounts one click unit`() {
        let clock = ContinuousClock()
        var now = clock.now
        let deadline = now.advanced(by: .milliseconds(1))
        do {
            try ModifierClickDispatchBarrier.waitForCompletion(
                baseline: .init(mouseUp: 7, modifierTransitions: 11),
                expectedIncrement: .init(mouseUp: 1, modifierTransitions: 2),
                deadline: deadline,
                now: { now },
                counters: { .init(mouseUp: 8, modifierTransitions: 12) },
                runLoopStep: { now = deadline })
            Issue.record("Expected the modifier-click delivery barrier to time out")
        } catch let failure as ModifierClickDispatchBarrierFailure {
            #expect(failure.failure.outcome.state == .indeterminate)
            #expect(failure.failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Unexpected barrier error: \(error)")
        }
    }
}
