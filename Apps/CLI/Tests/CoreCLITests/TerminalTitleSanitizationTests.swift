import Foundation
import Testing
@testable import PeekabooCLI

struct TerminalTitleSanitizationTests {
    @Test
    func `OSC payload cannot escape the title through control characters`() {
        let malicious = "fixture\u{0007}\u{001B}]52;c;ZmFrZQ==\u{0007}\n\r\u{009C}"
        let sanitized = sanitizedTerminalTitle(malicious)
        #expect(sanitized == "fixture]52;c;ZmFrZQ==")
        #expect(!sanitized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains))
    }

    @Test
    func `ordinary unicode titles retain their readable content`() {
        let title = "Agent: résumé 🦞 👩‍💻 – owned fixture"
        #expect(sanitizedTerminalTitle(title) == title)
    }
}
