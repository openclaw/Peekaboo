import Testing
@testable import PeekabooFoundation

struct RawPressPolicyTests {
    @Test
    func `chord names preserve backward and forward delete semantics`() throws {
        for name in ["delete", "Delete", "backspace", "del"] {
            #expect(try KeyboardChord(parsing: name).keys == ["delete"])
        }
        for name in ["forwarddelete", "forward_delete"] {
            #expect(try KeyboardChord(parsing: name).keys == ["forwarddelete"])
        }
        for name in ["cmd", "command", "Command"] {
            #expect(try KeyboardChord(parsing: "\(name)+c").keys == ["cmd", "c"])
        }
    }

    @Test
    func `unsupported modifier retains the invalid chord error`() {
        let error = #expect(throws: KeyboardChordError.self) {
            _ = try KeyboardChord(parsing: "super+c")
        }
        #expect(error == .invalid("super+c"))
        #expect(error?.errorDescription?.contains(KeyboardChord.syntaxHelp) == true)
        #expect(error?.errorDescription?.contains("peekaboo press --help") == true)
    }

    @Test
    func `raw press foreground refusal owns one canonical outcome`() {
        let outcome = RawPressPolicy.foregroundConsentRefusal

        #expect(RawPressPolicy.errorCode == .interactionFailed)
        #expect(outcome.state == .refused)
        #expect(outcome.effect == .refused)
        #expect(outcome.dispatchState == .none)
        #expect(outcome.retrySafety == .safe)
        #expect(outcome.escalation == .correctRequest)
        #expect(outcome.refusalReason == .foregroundConsentRequired)
        #expect(RawPressPolicy.foregroundConsentRequiredMessage.contains("fresh exact receipt"))
        #expect(RawPressPolicy.foregroundConsentRequiredHint.contains("non-dialog snapshot"))
        #expect(RawPressPolicy.foregroundConsentRequiredHint.contains("--foreground"))
        #expect(RawPressPolicy.foregroundConsentRequiredHint.contains("foreground=true"))
        #expect(RawPressPolicy.foregroundConsentRequiredHint.contains("semantic action"))
    }
}
