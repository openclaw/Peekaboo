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

    @Test(arguments: Settlement.allCases)
    func `typing waits for queued text and selection before the next edit`(
        settlement: Settlement) async throws
    {
        let fixture = Fixture(settlement: settlement)
        if settlement == .empty {
            let result = try await fixture.run()
            #expect(result.executionResult.outcome.state == .confirmedNoChange)
            #expect(result.executionResult.outcome.dispatchState == .none)
            #expect(fixture.textWrites.isEmpty)
            #expect(fixture.selectionWrites.isEmpty)
        } else if settlement == .emptyUnsupported {
            let failure = await #expect(throws: DesktopActionFailure.self) {
                _ = try await fixture.run()
            }
            #expect(failure?.outcome.state == .refused)
            #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
            #expect(failure?.outcome.retrySafety == .safe)
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
        let element = ActionInputMockAutomationElement(
            identifier: "editor",
            role: "AXTextField",
            frame: CGRect(x: 20, y: 20, width: 200, height: 30),
            value: "old",
            isValueSettable: true,
            isFocused: true)
        let native = Element(AXUIElementCreateApplication(777))
        var selection = CFRange(location: 3, length: 0)
        var pendingText: String?
        var pendingSelection: CFRange?
        var textWrites: [String] = []
        var selectionWrites: [CFRange] = []
        var observations = 0
        var events: [String] = []

        init(settlement: Settlement) {
            self.settlement = settlement
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
            }, processStartIdentity: { _ in 1 })
        }

        private var access: BackgroundInputDriver.FocusedTextEditAccess<ActionInputMockAutomationElement> {
            .init(
                focusedElement: { self.element },
                isEditable: { $0.isValueSettable },
                textValue: { $0.stringValue },
                selectedRange: { _ in self.selection },
                focusSnapshot: { element in
                    ExactWindowFocusSnapshot(
                        processIdentifier: 777,
                        windowID: 42,
                        frame: element.frame ?? .zero,
                        role: element.role,
                        identifier: element.identifier,
                        nativeElement: RetainedFocusElement(element: self.native.underlyingElement))
                },
                setText: { text, element in
                    guard element.stringValue != text else { return .noChange }
                    return try await self.observer.performObservedMutation(
                        on: element,
                        attribute: .value,
                        mutation: {
                            self.textWrites.append(text)
                            self.pendingText = text
                            return true
                        },
                        matches: { _ in element.stringValue == text }) ? .accessibilityValue : .unsupported
                },
                selectRange: { range, element in
                    if self.settlement == .selectionUnsupported || self.settlement == .emptyUnsupported {
                        return .unsupported
                    }
                    guard self.selection.location != range.location || self.selection.length != range.length
                    else { return .noChange }
                    return try await self.observer.performObservedMutation(
                        on: element,
                        attribute: .selectedTextRange,
                        mutation: {
                            self.selectionWrites.append(range)
                            self.pendingSelection = range
                            return true
                        },
                        matches: { _ in
                            self.selection.location == range.location && self.selection.length == range.length
                        })
                        ? .accessibilityValue : .unsupported
                })
        }

        func run() async throws -> TypeService.TypeActionExecutionSummary {
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
                self.settlement == .empty || self.settlement == .emptyUnsupported
                    ? [.clear] : [.clear, .text("abc"), .key(.leftArrow), .text("Z")],
                cadence: .fixed(milliseconds: 0),
                snapshotId: nil,
                automationTarget: .exactWindow(target),
                deliveryValidator: {},
                validatedReceiverProvider: { self.native })
        }
    }
}
