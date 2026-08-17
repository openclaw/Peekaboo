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

        XCTAssertEqual(sequence.values, ["focus", "identity"])
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
            exactWindowIdentityValidator: { candidate, candidateBounds in
                candidate.hasSameStableReceipt(as: identity) && candidateBounds == bounds
            })

        try await service.requireExactWindowKeyboardFocus(
            expectedWindowIdentity: identity,
            expectedWindowBounds: bounds,
            expectedFocusedElement: expected)

        XCTAssertFalse(applicationReaderUsed.value)
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

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
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
