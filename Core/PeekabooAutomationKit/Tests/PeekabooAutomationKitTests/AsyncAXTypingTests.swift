import ApplicationServices
import struct AXorcist.Element
import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct AsyncAXTypingTests {
    enum Settlement: CaseIterable {
        case completes, textStalls, secondTextStalls, selectionStalls, selectionUnsupported
        case empty, emptyUnsupported
    }

    enum SuspensionPoint: CaseIterable {
        case valuePreflight, valueSettlement, selectionPreflight, selectionSettlement
    }

    enum FocusChange: CaseIterable {
        case stable, reflow, sibling, missing, unfocused, wrongWindow, cancelled
        case lookupFailure, lookupCancellation
    }

    enum TypingMutation: CaseIterable {
        case character, editingKey
    }

    enum SourceStateMutation: CaseIterable {
        case text, clear, left, right, home, end, delete, forwardDelete, space

        var action: TypeAction {
            switch self {
            case .text: .text("x")
            case .clear: .clear
            case .left: .key(.leftArrow)
            case .right: .key(.rightArrow)
            case .home: .key(.home)
            case .end: .key(.end)
            case .delete: .key(.delete)
            case .forwardDelete: .key(.forwardDelete)
            case .space: .key(.space)
            }
        }
    }

    enum SourceStateInterference: CaseIterable {
        case text, selection
    }

    enum FailingGetter: CaseIterable {
        case focus, text
    }

    @Test(arguments: [false, true])
    func `value settlement never adopts a changed selection for another write`(alreadyDesired: Bool) async throws {
        let fixture = Fixture(settlement: .completes, suspension: .valueSettlement)
        fixture.selection = CFRange(location: 1, length: 0)
        let operation = Task { @MainActor in try await fixture.run(actions: [.text("x")]) }
        guard await fixture.entered.opensWithin(.seconds(2)) else {
            operation.cancel()
            await fixture.release.open()
            _ = try? await operation.value
            Issue.record("The value observation did not reach its selection-preservation gate")
            return
        }
        fixture.selection = CFRange(location: alreadyDesired ? 2 : 0, length: 0)
        await fixture.release.open()

        if alreadyDesired {
            let result = try await operation.value
            #expect(result.executionResult.outcome.dispatchState.unitCount?.rawValue == 1)
        } else {
            let failure = await #expect(throws: InputDeliveryIndeterminateError.self) { try await operation.value }
            #expect(failure?.emittedUnitCount == 1)
            #expect(failure?.retrySafe == false)
            #expect(failure?.delivery?.mechanism == .accessibilityValue)
        }
        #expect(fixture.textWrites == ["oxld"])
        #expect(fixture.selectionWrites.isEmpty)
        #expect(fixture.selection.location == (alreadyDesired ? 2 : 0))
        #expect(fixture.selection.length == 0)
        #expect(fixture.element.stringValue == "oxld")
        #expect(fixture.events.isEmpty)
        #expect(fixture.focusedReceiver === fixture.element)
    }

    @Test(arguments: FailingGetter.allCases, [false, true])
    func `initial getter failures preserve definite zero writes and prior prefixes`(
        getter: FailingGetter,
        hasPrefix: Bool) async throws
    {
        for cancelled in [false, true] {
            let fixture = Fixture(settlement: .completes)
            let error: any Error = cancelled ? CancellationError() : PeekabooError.permissionDeniedAccessibility
            if hasPrefix {
                fixture.failGetterAfterSelection = (getter, error)
            } else {
                fixture.fail(getter, with: error)
            }
            let actions: [TypeAction] = hasPrefix ? [.text("a"), .text("x")] : [.text("x")]
            if hasPrefix {
                let failure = await #expect(throws: InputDeliveryIndeterminateError.self) {
                    try await fixture.run(actions: actions)
                }
                #expect(failure?.emittedUnitCount == 1)
                #expect(failure?.retrySafe == false)
                #expect(failure?.delivery?.mechanism == .accessibilityValue)
            } else if cancelled {
                await #expect(throws: CancellationError.self) { try await fixture.run(actions: actions) }
            } else {
                let failure = await #expect(throws: DesktopActionFailure.self) {
                    try await fixture.run(actions: actions)
                }
                #expect(failure?.outcome.state == .refused)
                #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
                #expect(failure?.outcome.retrySafety == .safe)
            }
            #expect(fixture.textWrites == (hasPrefix ? ["olda"] : []))
            #expect(fixture.selectionWrites.map(\.location) == (hasPrefix ? [4] : []))
            #expect(fixture.events.isEmpty)
        }
    }

    @Test
    func `focused text matching requires exact optional UTF16 storage`() {
        #expect(BackgroundInputDriver.exactTextMatches(nil, nil))
        #expect(!BackgroundInputDriver.exactTextMatches(nil, ""))
        #expect(!BackgroundInputDriver.exactTextMatches("", nil))
        #expect(BackgroundInputDriver.exactTextMatches("e\u{0301}", "e\u{0301}"))
        #expect(!BackgroundInputDriver.exactTextMatches("\u{00E9}", "e\u{0301}"))
    }

    @Test
    func `typing replaces a canonically equivalent selection with requested storage`() async throws {
        let fixture = Fixture(settlement: .completes)
        fixture.element.value = "\u{00E9}"
        fixture.selection = CFRange(location: 0, length: 1)
        let replacement = "e\u{0301}"

        let result = try await fixture.run(actions: [.text(replacement)])

        #expect(result.executionResult.outcome.dispatchState.unitCount?.rawValue == 1)
        #expect(fixture.textWrites.count == 1)
        #expect(fixture.textWrites.first?.utf16.elementsEqual(replacement.utf16) == true)
        #expect(fixture.element.stringValue?.utf16.elementsEqual(replacement.utf16) == true)
        #expect(fixture.selectionWrites.map(\.location) == [2])
        #expect(fixture.selection.length == 0)
        #expect(fixture.events.isEmpty)
    }

    @Test
    func `text preflight refuses canonically equivalent UTF16 storage changes`() async throws {
        let precomposed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let fixture = Fixture(settlement: .completes, preflightToSuspend: 1)
        fixture.element.value = precomposed
        fixture.selection = CFRange(location: 0, length: 0)
        let operation = Task { @MainActor in try await fixture.run(actions: [.text("x")]) }
        guard await fixture.entered.opensWithin(.seconds(2)) else {
            operation.cancel()
            await fixture.release.open()
            _ = try? await operation.value
            Issue.record("The native reader did not reach its Unicode source-state preflight gate")
            return
        }
        #expect(!precomposed.utf16.elementsEqual(decomposed.utf16))
        fixture.element.value = decomposed
        await fixture.release.open()

        let failure = await #expect(throws: DesktopActionFailure.self) { try await operation.value }
        #expect(failure?.outcome.state == .refused)
        #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(failure?.outcome.retrySafety == .safe)
        #expect(fixture.textWrites.isEmpty)
        #expect(fixture.selectionWrites.isEmpty)
        #expect(fixture.events.isEmpty)
        #expect(fixture.selection.location == 0 && fixture.selection.length == 0)
        #expect(fixture.focusedReceiver === fixture.element)
        #expect(fixture.element.isFocused && fixture.windowIsCurrent)
        let finalText = try #require(fixture.element.stringValue)
        #expect(finalText.utf16.elementsEqual(decomposed.utf16))
    }

    @Test(arguments: SourceStateMutation.allCases, [false, true])
    func `suspended edits refuse changed source state on the same receiver`(
        mutation: SourceStateMutation,
        hasPrefix: Bool) async throws
    {
        for interference in SourceStateInterference.allCases {
            let fixture = Fixture(settlement: .completes, preflightToSuspend: hasPrefix ? 3 : 1)
            fixture.selection = CFRange(location: 1, length: 0)
            let actions: [TypeAction] = hasPrefix ? [.text("a"), mutation.action] : [mutation.action]
            let operation = Task { @MainActor in try await fixture.run(actions: actions) }
            guard await fixture.entered.opensWithin(.seconds(2)) else {
                operation.cancel()
                await fixture.release.open()
                _ = try? await operation.value
                Issue.record("The native reader did not reach its source-state preflight gate")
                return
            }
            fixture.apply(interference)
            await fixture.release.open()

            if hasPrefix {
                let failure = await #expect(throws: InputDeliveryIndeterminateError.self) { try await operation.value }
                #expect(failure?.emittedUnitCount == 1)
                #expect(failure?.retrySafe == false)
                #expect(failure?.delivery?.mechanism == .accessibilityValue)
            } else {
                let failure = await #expect(throws: DesktopActionFailure.self) { try await operation.value }
                #expect(failure?.outcome.state == .refused)
                #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
                #expect(failure?.outcome.retrySafety == .safe)
            }
            #expect(fixture.textWrites == (hasPrefix ? ["oald"] : []))
            #expect(fixture.selectionWrites.map(\.location) == (hasPrefix ? [2] : []))
            fixture.expectPreservedSourceState(
                interference,
                textBefore: hasPrefix ? "oald" : "old",
                selectionBefore: hasPrefix ? 2 : 1)
        }
    }

    @Test(arguments: [SourceStateMutation.left, .home], [false, true])
    func `cursor key reaching its desired range during preflight remains a no-op`(
        mutation: SourceStateMutation,
        hasPrefix: Bool) async throws
    {
        let fixture = Fixture(settlement: .completes, preflightToSuspend: hasPrefix ? 3 : 1)
        fixture.selection = CFRange(location: 1, length: 0)
        let nativeReceiver = try RetainedFocusElement(element: #require(fixture.element.underlyingAXElement))
        let actions: [TypeAction] = hasPrefix ? [.text("a"), mutation.action] : [mutation.action]
        let operation = Task { @MainActor in try await fixture.run(actions: actions) }
        guard await fixture.entered.opensWithin(.seconds(2)) else {
            operation.cancel()
            await fixture.release.open()
            _ = try? await operation.value
            Issue.record("The cursor key did not reach its selection preflight gate")
            return
        }
        let desiredLocation = mutation == .left && hasPrefix ? 1 : 0
        fixture.selection = CFRange(location: desiredLocation, length: 0)
        await fixture.release.open()

        let result = try await operation.value

        if hasPrefix {
            #expect(result.executionResult.outcome.state == .dispatchedUnverified)
            #expect(result.executionResult.outcome.dispatchState.unitCount == .one)
            #expect(result.executionResult.outcome.retrySafety == .unsafe)
            #expect(result.executionResult.outcome.delivery?.mechanism == .accessibilityValue)
        } else {
            #expect(result.executionResult.outcome.state == .confirmedNoChange)
            #expect(result.executionResult.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
        }
        #expect(fixture.textWrites == (hasPrefix ? ["oald"] : []))
        #expect(fixture.selectionWrites.map(\.location) == (hasPrefix ? [2] : []))
        #expect(fixture.selectionWrites.allSatisfy { $0.length == 0 })
        #expect(fixture.element.stringValue == (hasPrefix ? "oald" : "old"))
        #expect(fixture.selection.location == desiredLocation && fixture.selection.length == 0)
        #expect(fixture.focusedReceiver === fixture.element)
        let currentNativeReceiver = try #require(fixture.focusedReceiver?.underlyingAXElement)
        #expect(RetainedFocusElement(element: currentNativeReceiver) == nativeReceiver)
        #expect(fixture.element.isFocused && fixture.windowIsCurrent)
        #expect(fixture.events.isEmpty)
        #expect(fixture.observedSuspension)
    }

    @Test
    func `desired selection reached during preflight continues typing without another write`() async throws {
        let fixture = Fixture(settlement: .completes, preflightToSuspend: 2)
        fixture.selection = CFRange(location: 1, length: 0)
        let operation = Task { @MainActor in try await fixture.run(actions: [.text("xy")]) }
        guard await fixture.entered.opensWithin(.seconds(2)) else {
            operation.cancel()
            await fixture.release.open()
            _ = try? await operation.value
            Issue.record("The native reader did not reach selection preflight after the first character")
            return
        }
        #expect(fixture.textWrites == ["oxld"])
        #expect(fixture.element.stringValue == "oxld")
        #expect(fixture.selectionWrites.isEmpty)
        fixture.selection = CFRange(location: 2, length: 0)
        await fixture.release.open()

        let result = try await operation.value

        #expect(result.executionResult.outcome.dispatchState.unitCount?.rawValue == 2)
        #expect(result.executionResult.outcome.delivery?.mechanism == .accessibilityValue)
        #expect(fixture.textWrites == ["oxld", "oxyld"])
        #expect(fixture.selectionWrites.map(\.location) == [3])
        #expect(fixture.selectionWrites.allSatisfy { $0.length == 0 })
        #expect(fixture.selection.location == 3 && fixture.selection.length == 0)
        #expect(fixture.element.stringValue == "oxyld")
        #expect(fixture.focusedReceiver === fixture.element)
        #expect(fixture.element.isFocused && fixture.windowIsCurrent)
        #expect(fixture.events.isEmpty)
        #expect(fixture.observedSuspension)
    }

    @Test(arguments: SourceStateInterference.allCases)
    func `selection preflight preserves source edits after an accepted text value`(
        interference: SourceStateInterference) async throws
    {
        let fixture = Fixture(settlement: .completes, preflightToSuspend: 2)
        fixture.selection = CFRange(location: 1, length: 0)
        let operation = Task { @MainActor in try await fixture.run(actions: [.text("x")]) }
        guard await fixture.entered.opensWithin(.seconds(2)) else {
            operation.cancel()
            await fixture.release.open()
            _ = try? await operation.value
            Issue.record("The native reader did not reach selection preflight after the accepted value")
            return
        }
        #expect(fixture.textWrites == ["oxld"])
        #expect(fixture.element.stringValue == "oxld")
        fixture.apply(interference)
        await fixture.release.open()

        let failure = await #expect(throws: InputDeliveryIndeterminateError.self) { try await operation.value }
        #expect(failure?.emittedUnitCount == 1)
        #expect(failure?.retrySafe == false)
        #expect(failure?.delivery?.mechanism == .accessibilityValue)
        #expect(fixture.textWrites == ["oxld"])
        #expect(fixture.selectionWrites.isEmpty)
        fixture.expectPreservedSourceState(interference, textBefore: "oxld", selectionBefore: 1)
    }

    @Test(arguments: TypingMutation.allCases, [false, true])
    func `cancelled typing preflight preserves only its completed prefix`(
        mutation: TypingMutation,
        hasPrefix: Bool) async throws
    {
        // A completed character has one value preflight and one selection preflight.
        let fixture = Fixture(settlement: .completes, preflightToSuspend: hasPrefix ? 3 : 1)
        let nextAction: TypeAction = mutation == .character ? .text("x") : .key(.leftArrow)
        let actions: [TypeAction] = hasPrefix ? [.text("a"), nextAction] : [nextAction]
        let operation = Task { @MainActor in try await fixture.run(actions: actions) }
        guard await fixture.entered.opensWithin(.seconds(2)) else {
            operation.cancel()
            await fixture.release.open()
            _ = try? await operation.value
            Issue.record("The native reader did not reach its typing preflight gate")
            return
        }
        operation.cancel()
        await fixture.release.open()

        if hasPrefix {
            let failure = await #expect(throws: InputDeliveryIndeterminateError.self) { try await operation.value }
            #expect(failure?.emittedUnitCount == 1)
            #expect(failure?.retrySafe == false)
            #expect(failure?.delivery?.mechanism == .accessibilityValue)
        } else {
            await #expect(throws: CancellationError.self) { try await operation.value }
        }
        #expect(fixture.textWrites == (hasPrefix ? ["olda"] : []))
        #expect(fixture.selectionWrites.map(\.location) == (hasPrefix ? [4] : []))
        #expect(fixture.element.stringValue == (hasPrefix ? "olda" : "old"))
        #expect(fixture.events.isEmpty)
        #expect(fixture.observedSuspension)
    }

    @Test(arguments: SuspensionPoint.allCases, FocusChange.allCases)
    func `suspended text edits require fresh focus before each write`(
        suspension: SuspensionPoint,
        focusChange: FocusChange) async throws
    {
        let fixture = Fixture(settlement: .completes, suspension: suspension)
        let operation = Task { @MainActor in try await fixture.run(actions: [.clear, .text("x")]) }
        guard await fixture.entered.opensWithin(.seconds(2)) else {
            operation.cancel()
            await fixture.release.open()
            _ = try? await operation.value
            Issue.record("The native reader did not reach its suspension gate")
            return
        }
        switch focusChange {
        case .stable:
            break
        case .reflow:
            fixture.currentFrame = CGRect(x: 30, y: 40, width: 200, height: 40)
        case .sibling:
            // Identical metadata cannot transfer authority to a different native receiver.
            fixture.focusedReceiver = ActionInputMockAutomationElement(
                identifier: fixture.element.identifier,
                role: fixture.element.role,
                frame: fixture.element.frame,
                value: "other",
                isValueSettable: true,
                isFocused: true)
        case .missing:
            fixture.focusedReceiver = nil
        case .unfocused:
            fixture.element.isFocused = false
        case .wrongWindow:
            fixture.windowIsCurrent = false
        case .cancelled:
            operation.cancel()
        case .lookupFailure:
            fixture.focusLookupError = PeekabooError.permissionDeniedAccessibility
        case .lookupCancellation:
            fixture.focusLookupError = CancellationError()
        }
        await fixture.release.open()

        if focusChange == .stable || focusChange == .reflow {
            let result = try await operation.value
            #expect(result.executionResult.outcome.dispatchState.unitCount?.rawValue == 2)
            #expect(fixture.textWrites == ["", "x"])
            #expect(fixture.selectionWrites.map(\.location) == [0, 1])
            #expect(fixture.element.stringValue == "x")
        } else if suspension == .valuePreflight {
            if focusChange == .cancelled || focusChange == .lookupCancellation {
                await #expect(throws: CancellationError.self) { try await operation.value }
            } else {
                let failure = await #expect(throws: DesktopActionFailure.self) { try await operation.value }
                #expect(failure?.outcome.state == .refused)
                #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
                #expect(failure?.outcome.retrySafety == .safe)
            }
            #expect(fixture.textWrites.isEmpty)
            #expect(fixture.selectionWrites.isEmpty)
            #expect(fixture.element.stringValue == "old")
        } else {
            let failure = await #expect(throws: InputDeliveryIndeterminateError.self) { try await operation.value }
            #expect(failure?.emittedUnitCount == 1)
            #expect(failure?.retrySafe == false)
            #expect(failure?.delivery?.mechanism == .accessibilityValue)
            #expect(fixture.textWrites == [""])
            #expect(fixture.selectionWrites.map(\.location) == (suspension == .selectionSettlement ? [0] : []))
            #expect(fixture.element.stringValue == "")
        }
        #expect(fixture.events.isEmpty)
        #expect(fixture.observedSuspension)
    }

    @Test(arguments: Settlement.allCases)
    func `typing waits for queued text and selection before the next edit`(
        settlement: Settlement) async throws
    {
        let fixture = Fixture(settlement: settlement)
        if settlement == .empty || settlement == .emptyUnsupported {
            let result = try await fixture.run()
            #expect(result.executionResult.outcome.state == .confirmedNoChange)
            #expect(result.executionResult.outcome.dispatchState == .none)
            #expect(fixture.textWrites.isEmpty)
            #expect(fixture.selectionWrites.isEmpty)
        } else if settlement == .completes {
            let result = try await fixture.run()
            #expect(fixture.element.stringValue == "abZc")
            #expect(fixture.textWrites == ["", "a", "ab", "abc", "abZc"])
            #expect(fixture.selectionWrites.map(\.location) == [0, 1, 2, 3, 2, 3])
            #expect(fixture.selectionWrites.allSatisfy { $0.length == 0 })
            #expect(result.executionResult.outcome.dispatchState.unitCount?.rawValue == 6)
            #expect(result.executionResult.outcome.delivery?.mechanism == .accessibilityValue)
        } else {
            let failure = await #expect(throws: InputDeliveryIndeterminateError.self) {
                _ = try await fixture.run()
            }
            #expect(failure?.retrySafe == false)
            #expect(failure?.delivery?.mechanism == .accessibilityValue)
            #expect(failure?.emittedUnitCount == (settlement == .secondTextStalls ? 2 : 1))
            #expect(fixture.textWrites == (settlement == .secondTextStalls ? ["", "a"] : [""]))
            #expect(fixture.selectionWrites
                .count == ([.textStalls, .selectionUnsupported].contains(settlement) ? 0 : 1))
            #expect(fixture.element.stringValue == (settlement == .textStalls ? "old" : ""))
        }
        #expect(fixture.events.isEmpty)
        if settlement == .empty || settlement == .emptyUnsupported {
            #expect(fixture.observations == 0)
        } else {
            #expect(fixture.observations > 0 && fixture.observations < 30)
        }
    }

    @MainActor
    private final class Fixture {
        let settlement: Settlement
        let suspension: SuspensionPoint?
        let preflightToSuspend: Int?
        let element: ActionInputMockAutomationElement
        let native = Element(AXUIElementCreateApplication(777))
        let siblingNative = Element(AXUIElementCreateApplication(778))
        let entered = ActionLaneLatch()
        let release = ActionLaneLatch()
        var observedSuspension = false
        var nativePreflights = 0
        var focusedReceiver: ActionInputMockAutomationElement?
        var focusLookupError: (any Error)?
        var textLookupError: (any Error)?
        var failGetterAfterSelection: (FailingGetter, any Error)?
        var currentFrame = CGRect(x: 20, y: 20, width: 200, height: 30)
        var windowIsCurrent = true
        var selection = CFRange(location: 3, length: 0)
        var pendingText: String?
        var pendingSelection: CFRange?
        var textWrites: [String] = []
        var selectionWrites: [CFRange] = []
        var observations = 0
        var events: [String] = []

        func fail(_ getter: FailingGetter, with error: any Error) {
            switch getter {
            case .focus: self.focusLookupError = error
            case .text: self.textLookupError = error
            }
        }

        func apply(_ interference: SourceStateInterference) {
            switch interference {
            case .text:
                self.element.value = "user-edit-preserved"
            case .selection:
                self.selection = CFRange(location: 0, length: 1)
            }
        }

        func expectPreservedSourceState(
            _ interference: SourceStateInterference,
            textBefore: String,
            selectionBefore: Int)
        {
            #expect(self.element.stringValue == (interference == .text ? "user-edit-preserved" : textBefore))
            #expect(self.selection.location == (interference == .selection ? 0 : selectionBefore))
            #expect(self.selection.length == (interference == .selection ? 1 : 0))
            #expect(self.focusedReceiver === self.element)
            #expect(self.element.isFocused)
            #expect(self.windowIsCurrent)
            #expect(self.events.isEmpty)
            #expect(self.observedSuspension)
        }

        init(
            settlement: Settlement,
            suspension: SuspensionPoint? = nil,
            preflightToSuspend: Int? = nil)
        {
            self.settlement = settlement
            self.suspension = suspension
            self.preflightToSuspend = preflightToSuspend
            self.element = ActionInputMockAutomationElement(
                underlyingAXElement: suspension == nil && preflightToSuspend == nil
                    ? nil : self.native.underlyingElement,
                identifier: "editor",
                role: "AXTextField",
                frame: self.currentFrame,
                value: "old",
                isValueSettable: true,
                isFocused: true)
            self.focusedReceiver = self.element
            if settlement == .empty || settlement == .emptyUnsupported {
                self.element.value = ""
                self.selection = CFRange(location: 0, length: 0)
            }
        }

        private var observer: ActionInputDriver {
            ActionInputDriver(observationDelay: {
                self.observations += 1
                let textStalled = self.settlement == .textStalls ||
                    (self.settlement == .secondTextStalls && self.textWrites.count == 2)
                if !textStalled, let text = self.pendingText {
                    self.element.value = text
                    self.pendingText = nil
                }
                if self.settlement != .selectionStalls, let range = self.pendingSelection {
                    self.selection = range
                    self.pendingSelection = nil
                }
            }, processStartIdentity: { _ in 1 }, nativeReader: { _, _, attribute, _ in
                let shouldSuspend = await MainActor.run {
                    guard !self.observedSuspension else { return false }
                    if attribute == .identity {
                        self.nativePreflights += 1
                    }
                    let matches: Bool = if let preflightToSuspend = self.preflightToSuspend {
                        attribute == .identity && self.nativePreflights == preflightToSuspend
                    } else {
                        switch self.suspension {
                        case .valuePreflight: attribute == .identity && self.textWrites.isEmpty
                        case .valueSettlement: attribute == .value && self.textWrites.count == 1
                        case .selectionPreflight: attribute == .identity && self.textWrites.count == 1
                        case .selectionSettlement: attribute == .selectedTextRange && self.selectionWrites.count == 1
                        case nil: false
                        }
                    }
                    self.observedSuspension = matches
                    return matches
                }
                if shouldSuspend {
                    await self.entered.open()
                    await self.release.wait()
                }
                return await MainActor.run {
                    self.observations += 1
                    if attribute == .value, let text = self.pendingText {
                        self.element.value = text
                        self.pendingText = nil
                    }
                    if attribute == .selectedTextRange, let range = self.pendingSelection {
                        self.selection = range
                        self.pendingSelection = nil
                    }
                    return AXMutationObservationSnapshot(
                        identity: FocusedElementIdentity(
                            processIdentifier: 777,
                            windowID: 42,
                            role: "AXTextField",
                            identifier: "editor",
                            frame: self.currentFrame),
                        value: .string(self.element.stringValue ?? ""),
                        selectedTextRange: AXMutationTextRange(
                            location: self.selection.location,
                            length: self.selection.length))
                }
            })
        }

        private var access: BackgroundInputDriver.FocusedTextEditAccess<ActionInputMockAutomationElement> {
            .init(
                focusedElement: {
                    if let error = self.focusLookupError {
                        throw error
                    }
                    return self.focusedReceiver
                },
                sameReceiver: { $0 === $1 },
                isEditable: { $0.isValueSettable },
                textValue: {
                    if let error = self.textLookupError {
                        throw error
                    }
                    return $0.stringValue
                },
                selectedRange: { _ in self.selection },
                focusSnapshot: { element in
                    ExactWindowFocusSnapshot(
                        processIdentifier: 777,
                        windowID: 42,
                        frame: self.currentFrame,
                        role: element.role,
                        identifier: element.identifier,
                        nativeElement: RetainedFocusElement(
                            element: (element === self.element ? self.native : self.siblingNative).underlyingElement))
                },
                validateReceiver: { receiver in
                    guard self.windowIsCurrent, receiver.isFocused else {
                        throw DesktopActionFailure.preDispatchRefusal(
                            reason: .targetUnavailable,
                            message: "The fixture's exact window lost keyboard authority.")
                    }
                },
                setText: { text, element, beforeMutation in
                    try await self.observer.performObservedMutation(
                        on: element,
                        attribute: .value,
                        beforeMutation: beforeMutation,
                        mutation: {
                            self.textWrites.append(text)
                            self.pendingText = text
                            return .accessibilityValue
                        },
                        matches: { _ in BackgroundInputDriver.exactTextMatches(element.stringValue, text) })
                },
                selectRange: { range, element, beforeMutation in
                    if self.settlement == .selectionUnsupported || self.settlement == .emptyUnsupported {
                        return .unsupported
                    }
                    return try await self.observer.performObservedMutation(
                        on: element,
                        attribute: .selectedTextRange,
                        mutation: {
                            if try beforeMutation() {
                                return .noChange
                            }
                            self.selectionWrites.append(range)
                            self.pendingSelection = range
                            if let (getter, error) = self.failGetterAfterSelection {
                                self.fail(getter, with: error)
                                self.failGetterAfterSelection = nil
                            }
                            return .accessibilityValue
                        },
                        matches: { _ in
                            self.selection.location == range.location && self.selection.length == range.length
                        })
                })
        }

        func run(actions: [TypeAction]? = nil) async throws -> TypeService.TypeActionExecutionSummary {
            let coordinationRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("peekaboo-async-typing-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: coordinationRoot) }
            let driver = TargetedTypeInputDriver(
                insertText: { text, _, window, phase, receiver in
                    try await BackgroundInputDriver.insertTextIntoFocusedText(
                        text, exactWindow: window, phase: phase, validatedReceiver: receiver, access: self.access)
                },
                performTextKey: { key, _, window, phase, receiver in
                    try await BackgroundInputDriver.performFocusedTextKey(
                        key, exactWindow: window, phase: phase, validatedReceiver: receiver, access: self.access)
                },
                replaceText: { text, _, window, phase, receiver in
                    try await BackgroundInputDriver.replaceFocusedText(
                        with: text, exactWindow: window, phase: phase, validatedReceiver: receiver, access: self.access)
                },
                typeCharacter: { character, _ in self.events.append(String(character)) },
                tapKey: { code, _, _ in self.events.append(String(code)) })
            let service = TypeService(
                snapshotManager: InMemorySnapshotManager(),
                inputPolicy: UIInputPolicy(defaultStrategy: self.settlement == .emptyUnsupported
                    ? .actionOnly : .actionFirst),
                randomSource: SystemTypingCadenceRandomSource(),
                focusedElementSecurityProbe: { _ in false },
                targetedInputDriver: driver,
                targetBundleIdentifier: { _ in "example.async-typing" },
                processStartIdentityProvider: { _ in 1 },
                desktopOperationExecutor: DesktopOperationExecutor(
                    laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: coordinationRoot)))
            let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
            let target = try UIAutomationTarget.ExactWindow(
                identity: WindowMutationIdentity(
                    windowID: 42,
                    ownerProcessIdentifier: 777,
                    ownerProcessStartIdentity: 1,
                    capturedBounds: bounds),
                bounds: bounds,
                focusedElement: self.element.focusedElementIdentity)
            return try await service.typeActionsTrackingSecureInput(
                actions ?? (self.settlement == .empty || self.settlement == .emptyUnsupported
                    ? [.clear] : [.clear, .text("abc"), .key(.leftArrow), .text("Z")]),
                cadence: .fixed(milliseconds: 0),
                snapshotId: nil,
                automationTarget: .exactWindow(target),
                deliveryValidator: {},
                validatedReceiverProvider: { self.native })
        }
    }
}
