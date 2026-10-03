import ApplicationServices
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct BackgroundKeyboardReceiverStateTests {
    @Test
    func `stable retained editor and selection pass without a key-window read`() throws {
        let snapshot = Self.snapshot()
        let first = try BackgroundKeyboardReceiverState.read(
            applicationFocusedElement: { snapshot.nativeElement },
            snapshot: { snapshot },
            selection: { _ in TextSelectionRange(location: 2, length: 2) },
            retained: nil)
        let repeated = try BackgroundKeyboardReceiverState.read(
            applicationFocusedElement: { snapshot.nativeElement },
            snapshot: { snapshot },
            selection: { _ in first.selection },
            retained: first)
        #expect(first == repeated)
    }

    @Test(arguments: ["AXSecureTextField", "AXButton", "AXWebArea"])
    func `unsupported or secure receiver refuses`(role: String) {
        #expect(throws: (any Error).self) {
            try BackgroundKeyboardReceiverState.read(
                applicationFocusedElement: { Self.snapshot().nativeElement },
                snapshot: { Self.snapshot(role: role) },
                selection: { _ in TextSelectionRange(location: 0, length: 0) },
                retained: nil)
        }
    }

    @Test
    func `unreadable or secure subrole refuses before selection read`() {
        for snapshot in [Self.snapshot(subrole: "AXSecureTextField"), Self.snapshot(subroleReadable: false)] {
            var reads = 0
            #expect(throws: (any Error).self) {
                try BackgroundKeyboardReceiverState.read(
                    applicationFocusedElement: { snapshot.nativeElement },
                    snapshot: { snapshot },
                    selection: { _ in reads += 1; return nil },
                    retained: nil)
            }
            #expect(reads == 0)
        }
    }

    @Test
    func `canonical equivalence cannot conceal changed UTF16 text`() throws {
        let composed = Self.snapshot(value: "\u{00E9}")
        let decomposed = Self.snapshot(value: "e\u{0301}")
        #expect(composed.value == decomposed.value)
        var samples = 0
        #expect(throws: (any Error).self) {
            try BackgroundKeyboardReceiverState.read(
                applicationFocusedElement: { composed.nativeElement },
                snapshot: { samples += 1; return samples == 1 ? composed : decomposed },
                selection: { _ in TextSelectionRange(location: 0, length: 0) },
                retained: nil)
        }
    }

    @Test
    func `selection drift and out of bounds selections refuse`() {
        var reads = 0
        #expect(throws: (any Error).self) {
            try BackgroundKeyboardReceiverState.read(
                applicationFocusedElement: { Self.snapshot().nativeElement },
                snapshot: { Self.snapshot() },
                selection: { _ in reads += 1; return TextSelectionRange(location: reads, length: 0) },
                retained: nil)
        }
        #expect(throws: (any Error).self) {
            try BackgroundKeyboardReceiverState.read(
                applicationFocusedElement: { Self.snapshot().nativeElement },
                snapshot: { Self.snapshot() },
                selection: { _ in TextSelectionRange(location: 6, length: 1) },
                retained: nil)
        }
    }

    @Test
    func `changed native receiver refuses even when metadata matches`() {
        var samples = 0
        #expect(throws: (any Error).self) {
            try BackgroundKeyboardReceiverState.read(
                applicationFocusedElement: { Self.snapshot().nativeElement },
                snapshot: { samples += 1; return Self.snapshot(nativePID: samples == 1 ? 9001 : 9002) },
                selection: { _ in TextSelectionRange(location: 0, length: 0) },
                retained: nil)
        }
    }

    @Test
    func `missing or sibling app focus refuses unchanged target metadata before selection`() {
        let owners: [RetainedFocusElement?] = [nil, Self.snapshot(nativePID: 9002).nativeElement]
        for owner in owners {
            var selectionReads = 0
            #expect(throws: (any Error).self) {
                try BackgroundKeyboardReceiverState.read(
                    applicationFocusedElement: { owner },
                    snapshot: { Self.snapshot() },
                    selection: { _ in selectionReads += 1; return TextSelectionRange(location: 0, length: 0) },
                    retained: nil)
            }
            #expect(selectionReads == 0)
        }
    }

    @Test(arguments: [2, 3, 4])
    func `app focus takeover around or between samples refuses`(takeoverRead: Int) {
        var ownerReads = 0
        #expect(throws: (any Error).self) {
            try BackgroundKeyboardReceiverState.read(
                applicationFocusedElement: {
                    ownerReads += 1
                    return Self.snapshot(nativePID: ownerReads < takeoverRead ? 9001 : 9002).nativeElement
                },
                snapshot: { Self.snapshot() },
                selection: { _ in TextSelectionRange(location: 0, length: 0) },
                retained: nil)
        }
        #expect(ownerReads == takeoverRead)
    }

    @Test
    func `app focus read failure refuses without reading the target`() {
        struct FocusReadError: Error {}
        var targetReads = 0
        #expect(throws: FocusReadError.self) {
            try BackgroundKeyboardReceiverState.read(
                applicationFocusedElement: { throw FocusReadError() },
                snapshot: { targetReads += 1; return Self.snapshot() },
                selection: { _ in TextSelectionRange(location: 0, length: 0) },
                retained: nil)
        }
        #expect(targetReads == 0)
    }

    @Test(arguments: [false, true])
    @MainActor
    func `focus loss prevents later preparation and preserves the accepted prefix`(afterActivation: Bool) async throws {
        let snapshot = Self.snapshot()
        let sibling = Self.snapshot(nativePID: 9002).nativeElement
        var owner = afterActivation ? snapshot.nativeElement : sibling
        var activations = 0
        var pointers = 0
        func validate() throws {
            _ = try BackgroundKeyboardReceiverState.read(
                applicationFocusedElement: { owner },
                snapshot: { snapshot },
                selection: { _ in TextSelectionRange(location: 0, length: 0) },
                retained: nil)
        }
        do {
            _ = try await BackgroundWindowKeyboardPreparation.sequence(
                activation: {
                    try validate()
                    activations += 1
                    owner = sibling
                    return .dispatchedUnverified(
                        delivery: .init(mechanism: .nativeFramework, mode: .background),
                        evidence: .deliveryAccepted,
                        unitCount: .one)
                },
                pointer: {
                    try validate()
                    pointers += 1
                    return .dispatchedUnverified(
                        delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                        evidence: .deliveryAccepted,
                        unitCount: .one)
                },
                postvalidate: { Issue.record("Unexpected postvalidation after focus loss") })
            Issue.record("Expected application-focus refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == (afterActivation ? .indeterminate : .refused))
            #expect(failure.outcome.retrySafety == (afterActivation ? .unsafe : .safe))
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == (afterActivation ? 1 : nil))
        }
        #expect(activations == (afterActivation ? 1 : 0))
        #expect(pointers == 0)
    }

    private static func snapshot(
        role: String = kAXTextAreaRole,
        subrole: String? = nil,
        subroleReadable: Bool = true,
        value: String = "abcdef",
        nativePID: pid_t = 9001) -> ExactWindowFocusSnapshot
    {
        ExactWindowFocusSnapshot(
            processIdentifier: 9001,
            windowID: 100,
            frame: CGRect(x: 0, y: 32, width: 400, height: 200),
            role: role,
            subrole: subrole,
            subroleIsReadable: subroleReadable,
            value: value,
            nativeElement: RetainedFocusElement(element: AXUIElementCreateApplication(nativePID)))
    }
}
