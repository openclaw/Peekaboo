import Commander
import Testing
@testable import PeekabooCLI

struct CaptureActionCommandBindingTests {
    @Test
    func `Capture action command binding`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "mode": ["area"],
                "region": ["0,0,320,240"],
                "captureEngine": ["cg"],
                "durationLimit": ["5s"],
                "preRoll": ["100ms"],
                "postRoll": ["250ms"],
                "actionTimeout": ["3s"],
                "path": ["/tmp/action-capture"],
                "command": ["echo", "hello", "--flag"],
            ],
            flags: ["highlightChanges"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: CaptureActionCommand.self,
            parsedValues: parsed
        )
        #expect(command.mode == "area")
        #expect(command.region == "0,0,320,240")
        #expect(command.captureEngine == "cg")
        #expect(command.durationLimit?.seconds == 5)
        #expect(command.preRoll?.roundedMilliseconds == 100)
        #expect(command.postRoll?.roundedMilliseconds == 250)
        #expect(command.actionTimeout?.seconds == 3)
        #expect(command.path == "/tmp/action-capture")
        #expect(command.command == ["echo", "hello", "--flag"])
        #expect(command.highlightChanges == true)
    }

    @Test
    func `Capture action commander signature captures remaining command`() {
        let signature = CaptureActionCommand.commanderSignature()
        #expect(signature.options.contains { $0.label == "durationLimit" })
        #expect(signature.options.contains { $0.label == "command" && $0.parsing == .remaining })
        #expect(signature.arguments.last?.label == "command...")
        #expect(signature.arguments.last?.isOptional == true)
        #expect(signature.arguments.last?.parsing == .remaining)
        #expect(!signature.options.contains { $0.label == "duration" })
    }

    @Test
    func `Capture action command rejects mixed tail forms`() {
        let parsed = ParsedValues(
            positional: ["echo", "tail"],
            options: ["command": ["echo", "option"]],
            flags: []
        )

        #expect(throws: ValidationError.self) {
            _ = try CommanderCLIBinder.instantiateCommand(
                ofType: CaptureActionCommand.self,
                parsedValues: parsed
            )
        }
    }
}
