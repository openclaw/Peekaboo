import Foundation
import Testing
@testable import PeekabooCLI

struct TerminalTitleSanitizationTests {
    @Test(arguments: Array(0...0x1F) + Array(0x7F...0x9F))
    func `each terminal control is removed without dropping adjacent text`(value: Int) throws {
        let scalar = try #require(UnicodeScalar(value))
        #expect(sanitizedTerminalTitle("left\(scalar)right") == "leftright")
    }

    @Test
    func `OSC payload cannot escape the title through control characters`() {
        let malicious = "fixture\u{0007}\u{001B}]52;c;ZmFrZQ==\u{0007}\n\r\u{009C}"
        let sanitized = sanitizedTerminalTitle(malicious)
        #expect(sanitized == "fixture]52;c;ZmFrZQ==")
        #expect(!sanitized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains))
    }

    @Test
    func `ordinary unicode titles retain their readable content`() {
        let title = "Agent: résumé e\u{0301} 🦞 👩‍💻 👨‍👩‍👧‍👦 ~\u{00A0}a\u{200C}b – owned fixture"
        #expect(sanitizedTerminalTitle(title) == title)
    }

    @Test
    func `empty and already sanitized titles are stable`() {
        #expect(sanitizedTerminalTitle("").isEmpty)
        #expect(sanitizedTerminalTitle("\u{0000}\u{001B}\u{009C}").isEmpty)
        let once = sanitizedTerminalTitle("a\u{0007}b\u{001B}c")
        #expect(sanitizedTerminalTitle(once) == once)
    }
}
