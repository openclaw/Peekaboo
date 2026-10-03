import ApplicationServices
import Testing
@testable import PeekabooAutomationKit

struct BackgroundKeyboardReceiverStateTests {
    @Test
    func `stable retained editor and selection pass without a key-window read`() throws {
        let snapshot = Self.snapshot()
        let first = try BackgroundKeyboardReceiverState.read(
            snapshot: { snapshot }, selection: { _ in TextSelectionRange(location: 2, length: 2) }, retained: nil)
        let repeated = try BackgroundKeyboardReceiverState.read(
            snapshot: { snapshot }, selection: { _ in first.selection }, retained: first)
        #expect(first == repeated)
    }

    @Test(arguments: ["AXSecureTextField", "AXButton", "AXWebArea"])
    func `unsupported or secure receiver refuses`(role: String) {
        #expect(throws: (any Error).self) {
            try BackgroundKeyboardReceiverState.read(
                snapshot: { Self.snapshot(role: role) },
                selection: { _ in TextSelectionRange(location: 0, length: 0) }, retained: nil)
        }
    }

    @Test
    func `unreadable or secure subrole refuses before selection read`() {
        for snapshot in [Self.snapshot(subrole: "AXSecureTextField"), Self.snapshot(subroleReadable: false)] {
            var reads = 0
            #expect(throws: (any Error).self) {
                try BackgroundKeyboardReceiverState.read(
                    snapshot: { snapshot }, selection: { _ in reads += 1; return nil }, retained: nil)
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
                snapshot: { samples += 1; return samples == 1 ? composed : decomposed },
                selection: { _ in TextSelectionRange(location: 0, length: 0) }, retained: nil)
        }
    }

    @Test
    func `selection drift and out of bounds selections refuse`() {
        var reads = 0
        #expect(throws: (any Error).self) {
            try BackgroundKeyboardReceiverState.read(
                snapshot: { Self.snapshot() },
                selection: { _ in reads += 1; return TextSelectionRange(location: reads, length: 0) }, retained: nil)
        }
        #expect(throws: (any Error).self) {
            try BackgroundKeyboardReceiverState.read(
                snapshot: { Self.snapshot() },
                selection: { _ in TextSelectionRange(location: 6, length: 1) }, retained: nil)
        }
    }

    @Test
    func `changed native receiver refuses even when metadata matches`() {
        var samples = 0
        #expect(throws: (any Error).self) {
            try BackgroundKeyboardReceiverState.read(
                snapshot: { samples += 1; return Self.snapshot(nativePID: samples == 1 ? 9001 : 9002) },
                selection: { _ in TextSelectionRange(location: 0, length: 0) }, retained: nil)
        }
    }

    private static func snapshot(
        role: String = kAXTextAreaRole,
        subrole: String? = nil,
        subroleReadable: Bool = true,
        value: String = "abcdef",
        nativePID: pid_t = 9001) -> ExactWindowFocusSnapshot
    {
        ExactWindowFocusSnapshot(
            processIdentifier: 9001, windowID: 100,
            frame: CGRect(x: 0, y: 32, width: 400, height: 200),
            role: role, subrole: subrole, subroleIsReadable: subroleReadable,
            value: value, nativeElement: RetainedFocusElement(element: AXUIElementCreateApplication(nativePID)))
    }
}
