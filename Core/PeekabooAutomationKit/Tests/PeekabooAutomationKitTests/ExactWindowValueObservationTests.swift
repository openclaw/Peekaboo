import ApplicationServices
import CoreGraphics
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct ExactWindowValueObservationTests {
    enum Change: CaseIterable {
        case stable, reflow, window, role, identifier, replacement, missing, focusLost, focusUnreadable, secure
        case secureMetadataUnreadable
    }

    @Test(arguments: [KeyboardFocusValidationPhase.initial, .continuation], Change.allCases)
    func `value samples retain only authority observed after the value RPC`(
        phase: KeyboardFocusValidationPhase,
        change: Change) throws
    {
        let receiver = RetainedFocusElement(element: AXUIElementCreateApplication(4242))
        let replacement = RetainedFocusElement(element: AXUIElementCreateApplication(4243))
        let expected = FocusedElementIdentity(
            processIdentifier: 4242,
            windowID: 42,
            role: "AXTextField",
            identifier: "editor",
            frame: CGRect(x: 20, y: 30, width: 160, height: 24))
        let initial = Self.snapshot(expected: expected, receiver: receiver)
        var afterValueRead = false
        var focusReads = 0
        var snapshotReads = 0
        let result = DetachedExactWindowFocusReader.readValue(
            observation: (expected: expected, initialSnapshot: initial, phase: phase),
            readSnapshot: {
                #expect(afterValueRead)
                snapshotReads += 1
                guard change != .missing else { return nil }
                return ExactWindowFocusSnapshot(
                    processIdentifier: expected.processIdentifier,
                    windowID: change == .window ? 43 : expected.windowID,
                    frame: change == .reflow ? expected.frame.offsetBy(dx: 10, dy: 20) : expected.frame,
                    role: change == .role ? "AXButton" : expected.role,
                    subrole: change == .secure ? "AXSecureTextField" : nil,
                    subroleIsReadable: change != .secureMetadataUnreadable,
                    identifier: change == .identifier ? "sibling" : expected.identifier,
                    nativeElement: change == .replacement ? replacement : receiver)
            },
            readFocusedState: {
                focusReads += 1
                guard afterValueRead else { return true }
                switch change {
                case .focusLost: return false
                case .focusUnreadable: return nil
                default: return true
                }
            },
            readValue: {
                #expect(focusReads == 1)
                afterValueRead = true
                return "settled"
            })

        #expect(afterValueRead)
        #expect(snapshotReads == 1)
        switch change {
        case .stable, .secure, .secureMetadataUnreadable:
            let observed = try result.get()
            #expect(observed.value == (change == .stable ? "settled" : nil))
            #expect(observed.nativeElement == receiver)
            #expect(focusReads == 2)
        case .reflow where phase == .continuation:
            let observed = try result.get()
            #expect(observed.value == "settled")
            #expect(observed.frame == expected.frame.offsetBy(dx: 10, dy: 20))
            #expect(focusReads == 2)
        default:
            guard case let .failure(error) = result else {
                Issue.record("Receiver drift must not return a confirmed value")
                return
            }
            let expectedError: FocusedElementReceiptError = switch change {
            case .window: .windowMismatch
            case .role: .roleMismatch
            case .identifier: .identifierMismatch
            case .missing: .processMismatch
            case .focusUnreadable: .focusedAttributeUnreadable
            case .reflow: .frameMismatch
            default: .focusNotConfirmed
            }
            #expect(error == expectedError)
        }
    }

    @Test
    func `unreadable initial secure metadata never queries the value`() throws {
        let receiver = RetainedFocusElement(element: AXUIElementCreateApplication(4242))
        let expected = FocusedElementIdentity(
            processIdentifier: 4242,
            windowID: 42,
            role: "AXTextField",
            frame: CGRect(x: 20, y: 30, width: 160, height: 24))
        let initial = ExactWindowFocusSnapshot(
            processIdentifier: 4242,
            windowID: 42,
            frame: expected.frame,
            role: expected.role,
            subroleIsReadable: false,
            nativeElement: receiver)
        var reads = 0
        let result = DetachedExactWindowFocusReader.readValue(
            observation: (expected: expected, initialSnapshot: initial, phase: .initial),
            readSnapshot: { Self.snapshot(expected: expected, receiver: receiver) },
            readFocusedState: { true },
            readValue: { reads += 1; return "must remain unread" })
        #expect(try result.get().value == nil)
        #expect(reads == 0)
    }

    @Test
    func `native call budgets shrink within one deadline and reject late data`() {
        let started = ContinuousClock.now
        let deadline = started.advanced(by: .milliseconds(80))
        var now = started
        var timeouts: [Float] = []
        let read = {
            DetachedExactWindowFocusReader.readBeforeDeadline(
                deadline,
                now: { now },
                applyTimeout: { timeouts.append($0); return true },
                read: { now = now.advanced(by: .milliseconds(40)); return 1 })
        }
        #expect(read() == 1)
        #expect(read() == nil)
        #expect(read() == nil)
        #expect(timeouts.count == 2)
        #expect(abs(timeouts[0] - 0.05) < 0.000_001)
        #expect(abs(timeouts[1] - 0.04) < 0.000_001)
    }

    @Test(arguments: [false, true])
    func `expired budgets and failed timeout installation never query native attributes`(expired: Bool) {
        let now = ContinuousClock.now
        var installations = 0
        var reads = 0
        let result = DetachedExactWindowFocusReader.readBeforeDeadline(
            now.advanced(by: expired ? .milliseconds(-1) : .milliseconds(50)),
            now: { now },
            applyTimeout: { _ in installations += 1; return false },
            read: { reads += 1; return 1 })
        #expect(result == nil)
        #expect(reads == 0)
        #expect(installations == (expired ? 0 : 1))
    }

    @Test
    func `unfocused receivers are refused before reading their value`() {
        let receiver = RetainedFocusElement(element: AXUIElementCreateApplication(4242))
        let expected = FocusedElementIdentity(
            processIdentifier: 4242,
            windowID: 42,
            role: "AXTextField",
            frame: CGRect(x: 20, y: 30, width: 160, height: 24))
        let result = DetachedExactWindowFocusReader.readValue(
            observation: (
                expected: expected,
                initialSnapshot: Self.snapshot(expected: expected, receiver: receiver),
                phase: .initial),
            readSnapshot: {
                Issue.record("Unfocused baseline must stop before another read")
                return nil
            },
            readFocusedState: { false },
            readValue: {
                Issue.record("Unfocused baseline must not expose a value")
                return "unreachable"
            })
        #expect(result == .failure(.focusNotConfirmed))
    }

    private static func snapshot(
        expected: FocusedElementIdentity,
        receiver: RetainedFocusElement) -> ExactWindowFocusSnapshot
    {
        ExactWindowFocusSnapshot(
            processIdentifier: expected.processIdentifier,
            windowID: expected.windowID,
            frame: expected.frame,
            role: expected.role,
            identifier: expected.identifier,
            nativeElement: receiver)
    }
}
