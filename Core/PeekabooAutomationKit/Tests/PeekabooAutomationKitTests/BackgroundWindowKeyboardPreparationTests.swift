import CoreGraphics
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct BackgroundWindowKeyboardPreparationTests {
    @Test
    func `focus observation error does not claim a focus request was sent`() {
        #expect(FocusedElementReceiptError.focusNotConfirmed.errorDescription ==
            "The selected element did not report AXFocused=true.")
    }

    @Test(arguments: [0, 1, 2])
    func `read-only focus loss preserves the cause and only the earlier preparation prefix`(phase: Int) async throws {
        let target = try Self.observationTarget()
        func read() async throws {
            let _: Int = try await BackgroundWindowKeyboardPreparation.read(target: target) {
                throw FocusedElementReceiptError.focusNotConfirmed
            }
        }
        do {
            if phase == 0 {
                try await read()
            }
            _ = try await BackgroundWindowKeyboardPreparation.sequence(
                activation: { Self.activation },
                pointer: {
                    if phase == 1 {
                        try await read()
                    }
                    return Self.pointer
                },
                postvalidate: { try await read() })
            Issue.record("Expected observation refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == (phase == 0 ? .refused : .indeterminate))
            #expect(failure.outcome.retrySafety == (phase == 0 ? .safe : .unsafe))
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == (phase == 0 ? nil : (phase == 1 ? 1 : 4)))
            #expect(failure.causeDescription == FocusedElementReceiptError.focusNotConfirmed.errorDescription)
            #expect(failure.hint == "Observe the target again; this observation did not dispatch preparation input.")
            #expect(!failure.message.contains("native focus request"))
        }
    }

    @Test
    func `cancelled observation is a no-input refusal`() async throws {
        let target = try Self.observationTarget()
        do {
            let _: Int = try await BackgroundWindowKeyboardPreparation.read(target: target) {
                throw CancellationError()
            }
            Issue.record("Expected cancellation refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .requestCancelled)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.outcome.dispatchState.unitCount == nil)
        }
    }

    @Test
    func `observation never weakens an existing canonical failure`() async throws {
        let target = try Self.observationTarget()
        let existing = BackgroundWindowKeyboardPreparation.leafFailure(
            InputDeliveryIndeterminateError(
                operation: .click, emittedUnitCount: 1, causeDescription: "Pointer delivery was interrupted."),
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background))
        do {
            let _: Int = try await BackgroundWindowKeyboardPreparation.read(target: target) { throw existing }
            Issue.record("Expected retained failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure == existing)
        }
    }

    private static func observationTarget() throws -> UIAutomationTarget.ExactWindow {
        let bounds = CGRect(x: 0, y: 32, width: 500, height: 400)
        return try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 100, ownerProcessIdentifier: 9001, ownerProcessStartIdentity: 800),
            bounds: bounds)
    }

    @Test
    func `activation and ordinary pointer outcomes compose without asserting effect`() async throws {
        var order: [String] = []
        let result = try await BackgroundWindowKeyboardPreparation.sequence(
            activation: { order.append("activation"); return Self.activation },
            pointer: { order.append("pointer"); return Self.pointer },
            postvalidate: { order.append("validate") })
        #expect(order == ["activation", "pointer", "validate"])
        #expect(result.state == .dispatchedUnverified)
        #expect(result.delivery == .init(mechanism: .composite, mode: .background))
        #expect(result.dispatchState.unitCount?.rawValue == 4)
        #expect(result.retrySafety == .unsafe)
    }

    @Test(arguments: [0, 1, 2])
    func `failures preserve exactly the completed prefix`(phase: Int) async throws {
        do {
            _ = try await BackgroundWindowKeyboardPreparation.sequence(
                activation: {
                    if phase == 0 {
                        throw CancellationError()
                    }
                    return Self.activation
                },
                pointer: {
                    if phase == 1 {
                        throw CancellationError()
                    }
                    return Self.pointer
                },
                postvalidate: {
                    if phase == 2 {
                        throw CancellationError()
                    }
                })
            Issue.record("Expected interrupted preparation")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == (phase == 0 ? .refused : .indeterminate))
            #expect(failure.outcome.retrySafety == (phase == 0 ? .safe : .unsafe))
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == (phase == 0 ? nil : (phase == 1 ? 1 : 4)))
            if phase == 1 {
                #expect(failure.outcome.delivery == .init(mechanism: .nativeFramework, mode: .background))
            }
        }
    }

    @Test
    func `composed input failure retains the delivery cause after replacing its message`() {
        let detail = "Exact receiver observation failed. Held keys were released to the original process generation."
        let leaf = BackgroundWindowKeyboardPreparation.leafFailure(
            InputDeliveryIndeterminateError(operation: .hotkey, emittedUnitCount: 2, causeDescription: detail),
            delivery: .init(mechanism: .processTargetedEvents, mode: .background))
        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(.outcome(Self.activation))
        sequence.record(.outcome(Self.pointer))
        let failure = sequence.failure(combining: leaf, message: "Prepared background hotkey did not finish.")

        #expect(failure.message == "Prepared background hotkey did not finish.")
        #expect(failure.causeDescription == detail)
        #expect(failure.outcome.state == .indeterminate)
        #expect(failure.outcome.dispatchState.unitCount?.rawValue == 6)
        #expect(failure.outcome.retrySafety == .unsafe)
        #expect(failure.outcome.delivery == .init(mechanism: .composite, mode: .background))
    }

    @Test
    func `pointer interruption retains activation and actual pointer prefix`() async throws {
        do {
            _ = try await BackgroundWindowKeyboardPreparation.sequence(
                activation: { Self.activation },
                pointer: {
                    throw InputDeliveryIndeterminateError(
                        operation: .click, emittedUnitCount: 1,
                        delivery: .init(mechanism: .windowTargetedEvents, mode: .background))
                },
                postvalidate: { Issue.record("Unexpected postvalidation") })
            Issue.record("Expected pointer prefix")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 2)
            #expect(failure.outcome.delivery == .init(mechanism: .composite, mode: .background))
        }
    }

    @Test
    func `blank chrome loss after primer prevents down and preserves one emitted unit`() async throws {
        let identity = try WindowMutationIdentity(
            windowID: 100, ownerProcessIdentifier: 42, ownerProcessStartIdentity: 800)
        let receipt = WindowRoutedPointerDriver.RouteReceipt(
            identity: identity, bounds: CGRect(x: 0, y: 0, width: 500, height: 400),
            screenPoint: CGPoint(x: 400, y: 16))
        var events: [CGEventType] = []
        let driver = WindowRoutedPointerDriver(
            hasPostEventAccess: { true }, resolveRoute: { _, _, _ in receipt },
            routeIsCurrent: { _ in true }, processGenerationIsCurrent: { _ in true },
            makeEvent: { specification, point in
                CGEvent(
                    mouseEventSource: nil,
                    mouseType: specification.type,
                    mouseCursorPosition: point,
                    mouseButton: specification.button)
            },
            stampWindowLocation: { _, _ in true }, postSkyLight: { _, _ in true },
            postPublic: { event, _ in events.append(event.type) }, resolveTransport: { _ in .publicCGEvent },
            applicationIsVisible: { _ in true }, windowIsVisible: { _ in true }, sleep: { _ in })
        do {
            _ = try await driver.click(
                at: receipt.screenPoint, button: .left, count: 1,
                targetProcessIdentifier: 42, targetWindowID: 100,
                expectedWindowIdentity: identity, expectedWindowBounds: receipt.bounds,
                beforeButtonDown: { throw CancellationError() })
            Issue.record("Expected refusal after primer")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.emittedUnitCount == 1)
            #expect(error.delivery == .init(mechanism: .windowTargetedEvents, mode: .background))
        }
        #expect(events == [.mouseMoved])
    }

    private static var activation: DesktopActionOutcome {
        .dispatchedUnverified(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
    }

    private static var pointer: DesktopActionOutcome {
        .dispatchedUnverified(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(3))
    }
}
