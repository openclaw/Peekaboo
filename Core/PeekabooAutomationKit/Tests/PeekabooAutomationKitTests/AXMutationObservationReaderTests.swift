import ApplicationServices
import Foundation
import PeekabooFoundation
import Testing
@testable @_spi(Testing) import PeekabooAutomationKit

struct AXMutationObservationReaderTests {
    enum Change: CaseIterable {
        case stable, focusBefore, focusAfter, unreadableFocusBefore, unreadableFocusAfter
        case secureBefore, secureAfter, unreadableSubroleBefore, unreadableSubroleAfter
        case window, role, identifier, receiver, generationBefore, generationAfter, missingRange
    }

    @Test(arguments: Change.allCases)
    func `focused selection requires stable readable receiver evidence`(change: Change) {
        let reference = RetainedFocusElement(element: AXUIElementCreateApplication(4242))
        let replacement = RetainedFocusElement(element: AXUIElementCreateApplication(4243))
        var snapshots = 0
        var focusReads = 0
        var rangeReads = 0
        var generations = 0
        let observed = DetachedAXMutationReader.readSynchronously(
            request: (target: Self.target, attribute: .selectedTextRange, deadline: .now.advanced(by: .seconds(1))),
            requiresFocusedReceiver: true,
            processStartIdentity: {
                generations += 1
                return change == .generationBefore || (change == .generationAfter && generations == 2) ? 100 : 99
            },
            readSnapshot: { _ in
                snapshots += 1
                let after = snapshots == 2
                return Self.snapshot(
                    reference: after && change == .receiver ? replacement : reference,
                    windowID: after && change == .window ? 43 : 42,
                    role: after && change == .role ? "AXButton" : "AXTextField",
                    identifier: after && change == .identifier ? "sibling" : "editor",
                    secure: after ? change == .secureAfter : change == .secureBefore,
                    readable: after ? change != .unreadableSubroleAfter : change != .unreadableSubroleBefore)
            },
            readAttribute: { name, _ in
                if name == kAXFocusedAttribute {
                    focusReads += 1
                    if (focusReads == 1 && change == .unreadableFocusBefore) ||
                        (focusReads == 2 && change == .unreadableFocusAfter)
                    {
                        return nil
                    }
                    return NSNumber(value: !((focusReads == 1 && change == .focusBefore) ||
                            (focusReads == 2 && change == .focusAfter)))
                }
                #expect(name == kAXSelectedTextRangeAttribute)
                rangeReads += 1
                return change == .missingRange ? nil : Self.rangeValue()
            })
        if change == .stable {
            #expect(observed?.selectedTextRange == TextSelectionRange(location: 1, length: 2))
            #expect(observed?.focused == true)
            #expect(snapshots == 2 && focusReads == 2 && rangeReads == 1 && generations == 2)
        } else {
            #expect(observed?.selectedTextRange == nil)
        }
        if [.secureBefore, .unreadableSubroleBefore, .focusBefore, .unreadableFocusBefore, .generationBefore]
            .contains(change)
        {
            #expect(rangeReads == 0)
        }
        #expect(rangeReads <= 1)
        if change == .missingRange {
            #expect(snapshots == 1)
        }
    }

    @Test(arguments: [
        "generationBefore",
        "snapshotBefore",
        "focusBefore",
        "range",
        "snapshotAfter",
        "focusAfter",
        "generationAfter",
    ])
    func `expiry at every read stage discards the result without restarting its deadline`(stage: String) {
        let reference = RetainedFocusElement(element: AXUIElementCreateApplication(4242))
        let started = ContinuousClock.now
        let deadline = started.advanced(by: .milliseconds(50))
        var now = started
        var events: [String] = []
        var snapshots = 0
        var focusReads = 0
        var generations = 0
        let record = { (event: String) in
            events.append(event)
            if event == stage {
                now = deadline
            }
        }
        let result = DetachedAXMutationReader.readSynchronously(
            request: (target: Self.target, attribute: .selectedTextRange, deadline: deadline),
            requiresFocusedReceiver: true,
            now: { now },
            processStartIdentity: {
                generations += 1
                record(generations == 1 ? "generationBefore" : "generationAfter")
                return 99
            },
            readSnapshot: { receivedDeadline in
                #expect(receivedDeadline == deadline)
                snapshots += 1
                record(snapshots == 1 ? "snapshotBefore" : "snapshotAfter")
                return Self.snapshot(reference: reference)
            },
            readAttribute: { name, receivedDeadline in
                #expect(receivedDeadline == deadline)
                if name == kAXFocusedAttribute {
                    focusReads += 1
                    record(focusReads == 1 ? "focusBefore" : "focusAfter")
                    return kCFBooleanTrue
                }
                record("range")
                return Self.rangeValue()
            })
        #expect(result == nil)
        #expect(events.last == stage)
        #expect(events.filter { $0 == "range" }.count <= 1)
    }

    @Test(arguments: [
        AXMutationObservationAttribute.identity,
        .focused,
        .selected,
        .value,
        .selectedTextRange,
    ])
    func `mutation readback does not acquire the observation only focus requirement`(
        attribute: AXMutationObservationAttribute) throws
    {
        let reference = RetainedFocusElement(element: AXUIElementCreateApplication(4242))
        var reads: [String] = []
        let observed = try #require(DetachedAXMutationReader.readSynchronously(
            request: (target: Self.target, attribute: attribute, deadline: .now.advanced(by: .seconds(1))),
            processStartIdentity: { 99 },
            readSnapshot: { _ in Self.snapshot(reference: reference) },
            readAttribute: { name, _ in
                reads.append(name)
                switch name {
                case kAXFocusedAttribute: return kCFBooleanFalse
                case kAXSelectedAttribute: return kCFBooleanTrue
                case kAXValueAttribute: return "value" as CFString
                default: return Self.rangeValue()
                }
            }))
        #expect(reads.count == (attribute == .identity ? 0 : 1))
        #expect(reads.contains(kAXFocusedAttribute) == (attribute == .focused))
        if attribute == .focused {
            #expect(observed.focused == false)
        }
        if attribute == .selected {
            #expect(observed.selected == true)
        }
        if attribute == .selectedTextRange {
            #expect(observed.selectedTextRange == TextSelectionRange(location: 1, length: 2))
        }
    }

    @Test
    func `unreadable security metadata is not the same as an absent subrole`() {
        for error in [AXError.cannotComplete, .invalidUIElement, .failure, .apiDisabled, .notImplemented] {
            let result = DetachedExactWindowFocusReader.subroleObservation(.init(error: error, value: nil))
            #expect(!result.isReadable)
        }
        for error in [AXError.noValue, .attributeUnsupported] {
            let result = DetachedExactWindowFocusReader.subroleObservation(.init(error: error, value: nil))
            #expect(result.isReadable && result.value == nil)
        }
        #expect(!DetachedExactWindowFocusReader.subroleObservation(nil).isReadable)
        #expect(!DetachedExactWindowFocusReader.subroleObservation(.init(error: .success, value: nil)).isReadable)
        #expect(!DetachedExactWindowFocusReader.subroleObservation(.init(error: .success, value: 1)).isReadable)
        let secure = DetachedExactWindowFocusReader.subroleObservation(.init(
            error: .success,
            value: "AXSecureTextField"))
        #expect(secure.isReadable && secure.value == "AXSecureTextField")
    }

    @Test(arguments: [false, true])
    func `mutation value evidence is withheld for unreadable security metadata`(unreadableAfter: Bool) {
        let reference = RetainedFocusElement(element: AXUIElementCreateApplication(4242))
        var snapshots = 0
        var valueReads = 0
        let observed = DetachedAXMutationReader.readSynchronously(
            request: (target: Self.target, attribute: .value, deadline: .now.advanced(by: .seconds(1))),
            processStartIdentity: { 99 },
            readSnapshot: { _ in
                snapshots += 1
                return Self.snapshot(reference: reference, readable: (snapshots == 1) == unreadableAfter)
            },
            readAttribute: { name, _ in
                #expect(name == kAXValueAttribute)
                valueReads += 1
                return "after" as CFString
            })

        #expect(observed != nil)
        #expect(observed?.value == nil)
        #expect(observed?.legacyPresentation == nil)
        #expect(valueReads == (unreadableAfter ? 1 : 0))
        #expect(snapshots == 2)
    }

    @Test(arguments: [AXError.noValue, .attributeUnsupported])
    func `known absent subrole still permits mutation value evidence`(error: AXError) {
        let reference = RetainedFocusElement(element: AXUIElementCreateApplication(4242))
        let subrole = DetachedExactWindowFocusReader.subroleObservation(.init(error: error, value: nil))
        let observed = DetachedAXMutationReader.readSynchronously(
            request: (target: Self.target, attribute: .value, deadline: .now.advanced(by: .seconds(1))),
            processStartIdentity: { 99 },
            readSnapshot: { _ in Self.snapshot(reference: reference, readable: subrole.isReadable) },
            readAttribute: { _, _ in "after" as CFString })

        #expect(observed?.value == .string("after"))
        #expect(observed?.legacyPresentation == "after")
    }

    private static var target: AXMutationObservationTarget {
        AXMutationObservationTarget(
            processIdentifier: 4242,
            processStartIdentity: 99,
            expectedIdentity: FocusedElementIdentity(
                processIdentifier: 4242,
                windowID: 42,
                role: "AXTextField",
                identifier: "editor",
                frame: CGRect(x: 20, y: 30, width: 160, height: 24)))
    }

    private static func snapshot(
        reference: RetainedFocusElement,
        windowID: Int = 42,
        role: String = "AXTextField",
        identifier: String = "editor",
        secure: Bool = false,
        readable: Bool = true) -> ExactWindowFocusSnapshot
    {
        ExactWindowFocusSnapshot(
            processIdentifier: 4242,
            windowID: windowID,
            frame: CGRect(x: 20, y: 30, width: 160, height: 24),
            role: role,
            subrole: secure ? "AXSecureTextField" : nil,
            subroleIsReadable: readable,
            identifier: identifier,
            nativeElement: reference)
    }

    private static func rangeValue() -> AXValue? {
        var range = CFRange(location: 1, length: 2)
        return AXValueCreate(.cfRange, &range)
    }
}
