import CoreGraphics
import Foundation
import PeekabooFoundation
import XCTest
@testable import PeekabooAutomationKit

@MainActor
final class UIAutomationExactWindowFocusTests: XCTestCase {
    func testExactReaderAcceptsNativeAndNumericFocusedBooleans() {
        XCTAssertEqual(DetachedExactWindowFocusReader.focusedAttributeValue(true), true)
        XCTAssertEqual(DetachedExactWindowFocusReader.focusedAttributeValue(false), false)
        XCTAssertEqual(DetachedExactWindowFocusReader.focusedAttributeValue(NSNumber(value: 1)), true)
        XCTAssertEqual(DetachedExactWindowFocusReader.focusedAttributeValue(NSNumber(value: 0)), false)
    }

    func testExactReaderRejectsUnreadableFocusedValues() {
        XCTAssertNil(DetachedExactWindowFocusReader.focusedAttributeValue(nil))
        XCTAssertNil(DetachedExactWindowFocusReader.focusedAttributeValue("true"))
        XCTAssertNil(DetachedExactWindowFocusReader.focusedAttributeValue(NSNull()))
        XCTAssertNil(DetachedExactWindowFocusReader.focusedAttributeValue([1]))
    }

    func testUnresponsiveFocusedChildReaderDoesNotBlockMainActorPastDeadline() async throws {
        let started = LockedBoolean()
        let release = DispatchSemaphore(value: 0)
        let service = UIAutomationService(
            actionInputDriver: ActionInputDriver(),
            automationElementResolver: AutomationElementResolver(),
            exactWindowFocusReader: { _ in
                started.setTrue()
                release.wait()
                return nil
            })
        defer { release.signal() }

        let validation = Task { @MainActor in
            try await service.requireExactWindowKeyboardFocus(
                expectedWindowIdentity: WindowMutationIdentity(
                    windowID: 42,
                    ownerProcessIdentifier: 930_001,
                    ownerProcessStartIdentity: 1),
                expectedWindowBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        for _ in 0..<100 where !started.value {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(started.value)

        let heartbeat = expectation(description: "main actor remained responsive")
        Task { @MainActor in heartbeat.fulfill() }
        await fulfillment(of: [heartbeat], timeout: 0.1)

        let start = ContinuousClock.now
        do {
            try await validation.value
            XCTFail("Expected exact-window validation timeout")
        } catch let PeekabooError.invalidInput(message) {
            XCTAssertTrue(message.contains("target"))
        }
        XCTAssertLessThan(Self.seconds(start.duration(to: .now)), 0.5)
    }

    func testExactValueReadHonorsProvidedRemainingBudget() async throws {
        let processIdentifier: pid_t = 930_011
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 400)
        let focusedElement = FocusedElementIdentity(
            processIdentifier: processIdentifier,
            windowID: 42,
            role: "AXTextField",
            identifier: "editor",
            frame: CGRect(x: 20, y: 20, width: 200, height: 30))
        let target = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 42,
                ownerProcessIdentifier: processIdentifier,
                ownerProcessStartIdentity: 33,
                capturedBounds: bounds),
            bounds: bounds,
            focusedElement: focusedElement)
        let confirmation = try XCTUnwrap(ExactLiteralTypingEffectConfirmation.plan(
            actions: [.clear, .text("safe")],
            target: target))
        let started = LockedBoolean()
        let release = DispatchSemaphore(value: 0)
        let service = TypeService(
            randomSource: SystemTypingCadenceRandomSource(),
            exactFocusedElementValueReader: { _ in
                started.setTrue()
                release.wait()
                return .success(ExactWindowFocusSnapshot(
                    processIdentifier: processIdentifier,
                    windowID: 42,
                    frame: focusedElement.frame,
                    role: focusedElement.role,
                    identifier: focusedElement.identifier,
                    value: "safe"))
            },
            processStartIdentityProvider: { _ in 33 })
        defer { release.signal() }
        let start = ContinuousClock.now

        let value = await service.exactFocusedValue(
            for: confirmation,
            timeout: .milliseconds(40))

        XCTAssertNil(value)
        XCTAssertTrue(started.value)
        XCTAssertLessThan(Self.seconds(start.duration(to: .now)), 0.15)
    }

    func testSamePIDAndWindowIDReuseWithSameBoundsDispatchesNoKeyboardEvents() async throws {
        let bounds = CGRect(x: 10, y: 20, width: 800, height: 600)
        let staleIdentity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 930_002,
            ownerProcessStartIdentity: 111)
        let sequence = LockedStrings()
        let automation = UIAutomationService(
            actionInputDriver: ActionInputDriver(),
            automationElementResolver: AutomationElementResolver(),
            exactWindowFocusReader: { processIdentifier in
                sequence.append("focus")
                return ExactWindowFocusSnapshot(
                    processIdentifier: processIdentifier,
                    windowID: 42,
                    frame: CGRect(x: 100, y: 100, width: 20, height: 20))
            },
            exactKeyWindowReader: { processIdentifier in
                sequence.append("key-window")
                return ExactKeyWindowSnapshot(
                    processIdentifier: processIdentifier,
                    windowID: 42,
                    isSheet: false,
                    hasAttachedSheet: false)
            },
            exactWindowIdentityValidator: { identity, expectedBounds in
                sequence.append("identity")
                return identity == staleIdentity && expectedBounds == bounds
                    ? false // Same numeric PID/window/bounds, different process generation.
                    : true
            })
        var postedEventCount = 0
        let hotkey = HotkeyService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            postEventAccessEvaluator: { true },
            eventPoster: { _, _ in postedEventCount += 1 })

        do {
            _ = try await hotkey.hotkey(
                keys: "cmd,a",
                holdDuration: 0,
                targetProcessIdentifier: staleIdentity.ownerProcessIdentifier,
                deliveryValidator: {
                    try await automation.requireExactWindowKeyboardFocus(
                        expectedWindowIdentity: staleIdentity,
                        expectedWindowBounds: bounds)
                })
            XCTFail("Expected reused process generation to fail closed")
        } catch let PeekabooError.invalidInput(message) {
            XCTAssertTrue(message.contains("target"))
        }

        XCTAssertEqual(sequence.values, ["focus", "key-window", "identity"])
        XCTAssertEqual(postedEventCount, 0)
    }

    func testFocusTargetIdentityRejectsReusedIDAndChangedBounds() {
        let bounds = CGRect(x: 10, y: 20, width: 800, height: 600)
        let expected = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 930_006,
            ownerProcessStartIdentity: 111,
            capturedBounds: bounds)
        let matching = FocusTargetIdentityObservation(
            processStartIdentity: 111,
            windowOwnerProcessIdentifier: 930_006,
            windowBounds: bounds,
            axProcessIdentifier: 930_006,
            axWindowID: 42,
            axBounds: bounds)

        XCTAssertTrue(focusTargetIdentityMatches(expected: expected, observation: matching))
        XCTAssertFalse(focusTargetIdentityMatches(
            expected: expected,
            observation: FocusTargetIdentityObservation(
                processStartIdentity: 222,
                windowOwnerProcessIdentifier: 930_006,
                windowBounds: bounds,
                axProcessIdentifier: 930_006,
                axWindowID: 42,
                axBounds: bounds)))
        XCTAssertFalse(focusTargetIdentityMatches(
            expected: expected,
            observation: FocusTargetIdentityObservation(
                processStartIdentity: 111,
                windowOwnerProcessIdentifier: 930_006,
                windowBounds: bounds.offsetBy(dx: 20, dy: 0),
                axProcessIdentifier: 930_006,
                axWindowID: 42,
                axBounds: bounds.offsetBy(dx: 20, dy: 0))))
    }

    func testSameWindowSiblingFocusDoesNotMatchClickedDestination() async throws {
        let windowIdentity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 930_003,
            ownerProcessStartIdentity: 1)
        let service = UIAutomationService(
            actionInputDriver: ActionInputDriver(),
            automationElementResolver: AutomationElementResolver(),
            exactFocusedElementReader: { expected in
                .success(ExactWindowFocusSnapshot(
                    processIdentifier: expected.processIdentifier,
                    windowID: 42,
                    frame: CGRect(x: 300, y: 100, width: 200, height: 30),
                    role: "AXTextField",
                    title: "Sibling",
                    identifier: "sibling"))
            },
            exactKeyWindowReader: { processIdentifier in
                ExactKeyWindowSnapshot(
                    processIdentifier: processIdentifier,
                    windowID: 42,
                    isSheet: false,
                    hasAttachedSheet: false)
            },
            exactWindowIdentityValidator: { _, _ in true })

        do {
            try await service.requireExactWindowKeyboardFocus(
                expectedWindowIdentity: windowIdentity,
                expectedWindowBounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                expectedFocusedElement: FocusedElementIdentity(
                    processIdentifier: windowIdentity.ownerProcessIdentifier,
                    windowID: windowIdentity.windowID,
                    role: "AXTextField",
                    title: "Clicked",
                    identifier: "clicked",
                    frame: CGRect(x: 50, y: 100, width: 200, height: 30)))
            XCTFail("Expected sibling focus to fail the clicked-destination proof")
        } catch let PeekabooError.invalidInput(message) {
            XCTAssertTrue(message.contains("target"))
        }
    }

    func testExactReceiptValidationDoesNotConsultApplicationFocusedElement() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 930_004,
            ownerProcessStartIdentity: 77,
            capturedBounds: bounds)
        let expected = FocusedElementIdentity(
            processIdentifier: identity.ownerProcessIdentifier,
            windowID: identity.windowID,
            role: "AXTextField",
            identifier: "inactive-editor",
            frame: CGRect(x: 50, y: 100, width: 200, height: 30))
        let applicationReaderUsed = LockedBoolean()
        let service = UIAutomationService(
            actionInputDriver: ActionInputDriver(),
            automationElementResolver: AutomationElementResolver(),
            exactWindowFocusReader: { _ in
                applicationReaderUsed.setTrue()
                return nil
            },
            exactFocusedElementReader: { receipt in
                .success(ExactWindowFocusSnapshot(
                    processIdentifier: receipt.processIdentifier,
                    windowID: receipt.windowID,
                    frame: receipt.frame,
                    role: receipt.role,
                    title: receipt.title,
                    identifier: receipt.identifier))
            },
            exactKeyWindowReader: { processIdentifier in
                ExactKeyWindowSnapshot(
                    processIdentifier: processIdentifier,
                    windowID: identity.windowID,
                    isSheet: false,
                    hasAttachedSheet: false)
            },
            exactWindowIdentityValidator: { candidate, candidateBounds in
                candidate.hasSameStableReceipt(as: identity) && candidateBounds == bounds
            })

        try await service.requireExactWindowKeyboardFocus(
            expectedWindowIdentity: identity,
            expectedWindowBounds: bounds,
            expectedFocusedElement: expected)

        XCTAssertFalse(applicationReaderUsed.value)
    }

    func testInactiveApplicationFocusedElementCannotAuthorizeAnotherInternalKeyWindow() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 930_007,
            ownerProcessStartIdentity: 92,
            capturedBounds: bounds)
        let expected = FocusedElementIdentity(
            processIdentifier: identity.ownerProcessIdentifier,
            windowID: identity.windowID,
            role: "AXTextField",
            identifier: "inactive-editor",
            frame: CGRect(x: 50, y: 100, width: 200, height: 30))
        let service = UIAutomationService(
            actionInputDriver: ActionInputDriver(),
            automationElementResolver: AutomationElementResolver(),
            exactFocusedElementReader: { receipt in
                .success(ExactWindowFocusSnapshot(
                    processIdentifier: receipt.processIdentifier,
                    windowID: receipt.windowID,
                    frame: receipt.frame,
                    role: receipt.role,
                    title: receipt.title,
                    identifier: receipt.identifier))
            },
            exactKeyWindowReader: { processIdentifier in
                ExactKeyWindowSnapshot(
                    processIdentifier: processIdentifier,
                    windowID: identity.windowID + 1,
                    isSheet: false,
                    hasAttachedSheet: false)
            },
            exactWindowIdentityValidator: { _, _ in true })

        do {
            try await service.requireExactWindowKeyboardFocus(
                expectedWindowIdentity: identity,
                expectedWindowBounds: bounds,
                expectedFocusedElement: expected)
            XCTFail("Expected internal key-window mismatch to fail closed")
        } catch let PeekabooError.invalidInput(message) {
            XCTAssertTrue(message.contains("target"), message)
        }
    }

    func testMatchingFocusedElementAndInternalKeyWindowAuthorizeExactTyping() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 930_008,
            ownerProcessStartIdentity: 93,
            capturedBounds: bounds)
        let expected = FocusedElementIdentity(
            processIdentifier: identity.ownerProcessIdentifier,
            windowID: identity.windowID,
            role: "AXTextField",
            identifier: "editor",
            frame: CGRect(x: 50, y: 100, width: 200, height: 30))
        let service = UIAutomationService(
            actionInputDriver: ActionInputDriver(),
            automationElementResolver: AutomationElementResolver(),
            exactFocusedElementReader: { receipt in
                .success(ExactWindowFocusSnapshot(
                    processIdentifier: receipt.processIdentifier,
                    windowID: receipt.windowID,
                    frame: receipt.frame,
                    role: receipt.role,
                    title: receipt.title,
                    identifier: receipt.identifier))
            },
            exactKeyWindowReader: { processIdentifier in
                ExactKeyWindowSnapshot(
                    processIdentifier: processIdentifier,
                    windowID: identity.windowID,
                    isSheet: false,
                    hasAttachedSheet: false)
            },
            exactWindowIdentityValidator: { candidate, candidateBounds in
                candidate.hasSameStableReceipt(as: identity) && candidateBounds == bounds
            })

        try await service.requireExactWindowKeyboardFocus(
            expectedWindowIdentity: identity,
            expectedWindowBounds: bounds,
            expectedFocusedElement: expected)
    }

    func testWrongKeyWindowOwnerPIDCannotAuthorizeExactTyping() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 930_009,
            ownerProcessStartIdentity: 94,
            capturedBounds: bounds)
        let service = UIAutomationService(
            actionInputDriver: ActionInputDriver(),
            automationElementResolver: AutomationElementResolver(),
            exactWindowFocusReader: { processIdentifier in
                ExactWindowFocusSnapshot(
                    processIdentifier: processIdentifier,
                    windowID: identity.windowID,
                    frame: CGRect(x: 50, y: 100, width: 200, height: 30))
            },
            exactKeyWindowReader: { _ in
                ExactKeyWindowSnapshot(
                    processIdentifier: identity.ownerProcessIdentifier + 1,
                    windowID: identity.windowID,
                    isSheet: false,
                    hasAttachedSheet: false)
            },
            exactWindowIdentityValidator: { _, _ in true })

        do {
            try await service.requireExactWindowKeyboardFocus(
                expectedWindowIdentity: identity,
                expectedWindowBounds: bounds)
            XCTFail("Expected wrong key-window owner PID to fail closed")
        } catch let PeekabooError.invalidInput(message) {
            XCTAssertTrue(message.contains("target"), message)
        }
    }

    func testAttachedSheetOnExpectedParentRefusesBeforeKeyboardDispatch() async throws {
        let fixture = self.exactSheetKeyboardFixture(
            processIdentifier: 930_010,
            processStartIdentity: 95,
            isSheet: false,
            hasAttachedSheet: true)

        do {
            _ = try await fixture.hotkey.hotkey(
                keys: "cmd,a",
                holdDuration: 0,
                targetProcessIdentifier: fixture.identity.ownerProcessIdentifier,
                deliveryValidator: {
                    try await fixture.automation.requireExactWindowKeyboardFocus(
                        expectedWindowIdentity: fixture.identity,
                        expectedWindowBounds: fixture.bounds)
                })
            XCTFail("Expected an attached sheet to invalidate the parent keyboard target")
        } catch let PeekabooError.invalidInput(message) {
            XCTAssertTrue(message.contains("attached sheet"), message)
        }

        XCTAssertEqual(fixture.postedEvents.value, 0)
    }

    func testExactSheetTargetRemainsEligibleForKeyboardDispatch() async throws {
        let processIdentifier = getpid()
        let fixture = self.exactSheetKeyboardFixture(
            processIdentifier: processIdentifier,
            processStartIdentity: SystemIdentityResolver.processStartIdentity(processIdentifier) ?? 96,
            isSheet: true,
            hasAttachedSheet: false)

        _ = try await fixture.hotkey.hotkey(
            keys: "cmd,a",
            holdDuration: 0,
            targetProcessIdentifier: fixture.identity.ownerProcessIdentifier,
            deliveryValidator: {
                try await fixture.automation.requireExactWindowKeyboardFocus(
                    expectedWindowIdentity: fixture.identity,
                    expectedWindowBounds: fixture.bounds)
            })

        XCTAssertGreaterThan(fixture.postedEvents.value, 0)
    }

    func testExactSheetWithNestedAttachedSheetRefusesBeforeKeyboardDispatch() async throws {
        let fixture = self.exactSheetKeyboardFixture(
            processIdentifier: 930_013,
            processStartIdentity: 97,
            isSheet: true,
            hasAttachedSheet: true)

        do {
            _ = try await fixture.hotkey.hotkey(
                keys: "cmd,a",
                holdDuration: 0,
                targetProcessIdentifier: fixture.identity.ownerProcessIdentifier,
                deliveryValidator: {
                    try await fixture.automation.requireExactWindowKeyboardFocus(
                        expectedWindowIdentity: fixture.identity,
                        expectedWindowBounds: fixture.bounds)
                })
            XCTFail("Expected a nested attached sheet to invalidate the exact sheet target")
        } catch let PeekabooError.invalidInput(message) {
            XCTAssertTrue(message.contains("attached sheet"), message)
        }

        XCTAssertEqual(fixture.postedEvents.value, 0)
    }

    func testExactReceiptMismatchReturnsTypedPreDispatchRefusal() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 930_005,
            ownerProcessStartIdentity: 78,
            capturedBounds: bounds)
        let expected = FocusedElementIdentity(
            processIdentifier: identity.ownerProcessIdentifier,
            windowID: identity.windowID,
            role: "AXTextField",
            identifier: "editor",
            frame: CGRect(x: 50, y: 100, width: 200, height: 30))
        let service = UIAutomationService(
            actionInputDriver: ActionInputDriver(),
            automationElementResolver: AutomationElementResolver(),
            exactFocusedElementReader: { _ in .failure(.identifierMismatch) },
            exactWindowIdentityValidator: { _, _ in true })

        do {
            try await service.requireExactWindowKeyboardFocus(
                expectedWindowIdentity: identity,
                expectedWindowBounds: bounds,
                expectedFocusedElement: expected)
            XCTFail("Expected mismatched exact focus receipt to refuse")
        } catch let PeekabooError.invalidInput(message) {
            XCTAssertTrue(message.contains("identifier changed"))
        }
    }

    /// A window that does not hold its application's keyboard focus can never receive background
    /// keystrokes, and it also refuses accessibility focus requests, so "retry" and "focus it first"
    /// are both dead ends. The refusal must hand back the route that does reach such a window.
    func testUnfocusedExactWindowRefusalNamesTheAccessibilityWriteRoute() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 930_006,
            ownerProcessStartIdentity: 91,
            capturedBounds: bounds)
        let service = UIAutomationService(
            actionInputDriver: ActionInputDriver(),
            automationElementResolver: AutomationElementResolver(),
            exactWindowFocusReader: { processIdentifier in
                ExactWindowFocusSnapshot(
                    processIdentifier: processIdentifier,
                    windowID: identity.windowID + 1,
                    frame: CGRect(x: 50, y: 100, width: 200, height: 30))
            },
            exactWindowIdentityValidator: { _, _ in true })

        do {
            try await service.requireExactWindowKeyboardFocus(
                expectedWindowIdentity: identity,
                expectedWindowBounds: bounds)
            XCTFail("Expected an unfocused exact window to refuse background keystrokes")
        } catch let PeekabooError.invalidInput(message) {
            XCTAssertTrue(message.contains("set-value"), message)
            XCTAssertTrue(message.contains("set_value"), message)
            XCTAssertTrue(message.contains("accessibility value"), message)
        }
    }

    private func exactSheetKeyboardFixture(
        processIdentifier: pid_t,
        processStartIdentity: UInt64,
        isSheet: Bool,
        hasAttachedSheet: Bool) -> ExactSheetKeyboardFixture
    {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: processIdentifier,
            ownerProcessStartIdentity: processStartIdentity,
            capturedBounds: bounds)
        let automation = UIAutomationService(
            actionInputDriver: ActionInputDriver(),
            automationElementResolver: AutomationElementResolver(),
            exactWindowFocusReader: { observedProcessIdentifier in
                ExactWindowFocusSnapshot(
                    processIdentifier: observedProcessIdentifier,
                    windowID: identity.windowID,
                    frame: CGRect(x: 50, y: 100, width: 200, height: 30))
            },
            exactKeyWindowReader: { observedProcessIdentifier in
                ExactKeyWindowSnapshot(
                    processIdentifier: observedProcessIdentifier,
                    windowID: identity.windowID,
                    isSheet: isSheet,
                    hasAttachedSheet: hasAttachedSheet)
            },
            exactWindowIdentityValidator: { candidate, candidateBounds in
                candidate == identity && candidateBounds == bounds
            })
        let postedEvents = LockedCounter()
        let hotkey = HotkeyService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            postEventAccessEvaluator: { true },
            eventPoster: { _, _ in postedEvents.increment() })
        return ExactSheetKeyboardFixture(
            bounds: bounds,
            identity: identity,
            automation: automation,
            hotkey: hotkey,
            postedEvents: postedEvents)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

@MainActor
private struct ExactSheetKeyboardFixture {
    let bounds: CGRect
    let identity: WindowMutationIdentity
    let automation: UIAutomationService
    let hotkey: HotkeyService
    let postedEvents: LockedCounter
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []

    var values: [String] {
        self.lock.withLock { self.storedValues }
    }

    func append(_ value: String) {
        self.lock.withLock { self.storedValues.append(value) }
    }
}

private final class LockedBoolean: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        self.lock.withLock { self.storedValue }
    }

    func setTrue() {
        self.lock.withLock { self.storedValue = true }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        self.lock.withLock { self.storedValue }
    }

    func increment() {
        self.lock.withLock { self.storedValue += 1 }
    }
}
