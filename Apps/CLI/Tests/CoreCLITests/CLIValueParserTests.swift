import Commander
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
struct CLIValueParserTests {
    @Test
    func `Duration parser treats bare values as milliseconds`() throws {
        #expect(try #require(CLIDuration(argument: "500")).milliseconds == 500)
    }

    @Test
    func `Duration parser accepts millisecond suffixes`() throws {
        #expect(try #require(CLIDuration(argument: "500ms")).milliseconds == 500)
    }

    @Test
    func `Duration parser accepts second suffixes`() throws {
        #expect(try #require(CLIDuration(argument: "2s")).milliseconds == 2000)
    }

    @Test
    func `Duration parser accepts fractional seconds`() throws {
        #expect(try #require(CLIDuration(argument: "1.5s")).milliseconds == 1500)
    }

    @Test
    func `Duration parser rejects invalid values`() {
        #expect(CLIDuration(argument: "") == nil)
        #expect(CLIDuration(argument: "-1") == nil)
        #expect(CLIDuration(argument: "1m") == nil)
        #expect(CLIDuration(argument: "NaN") == nil)
        #expect(CLIDuration(argument: String(Int.max)) == nil)
    }

    @Test
    @MainActor
    func `Property backed commands use the duration grammar`() throws {
        let capture = try CaptureLiveCommand.parse(["--mode", "screen", "--duration", "1.5s"])
        #expect(capture.mode == "screen")
        #expect(capture.duration?.milliseconds == 1500)

        let video = try CaptureVideoCommand.parse(["demo.mov", "--every", "500ms", "--start", "2s"])
        #expect(video.every?.roundedMilliseconds == 500)
        #expect(video.start?.seconds == 2)

        let config = try ConfigCommand.StatusCommand.parse(["--timeout", "3s"])
        #expect(config.timeout.seconds == 3)

        let relaunch = try AppCommand.RelaunchSubcommand.parse([
            "TextEdit", "--wait", "250ms", "--foreground",
        ])
        #expect(relaunch.wait.roundedMilliseconds == 250)

        let dialog = try DialogCommand.ListSubcommand.parse(["--timeout", "2s"])
        #expect(dialog.timeout.seconds == 2)
    }

    @Test
    func `Modifier parser normalizes aliases`() throws {
        let modifiers = try #require(CLIModifierList(argument: "command,shift,alt,control,fn"))
        #expect(modifiers.description == "cmd,shift,option,ctrl,fn")
        #expect(CLIModifierList(argument: "cmd,hyper") == nil)
        #expect(CLIModifierList(argument: "cmd,command") == nil)
    }

    @Test
    @MainActor
    func `Input commands share the focus flag matrix`() {
        Self.expectFocusFlags(ClickCommand.commanderSignature(), includesBackground: true)
        Self.expectFocusFlags(TypeCommand.commanderSignature(), includesBackground: true)
        Self.expectFocusFlags(PressCommand.commanderSignature(), includesBackground: true)
        Self.expectFocusFlags(ScrollCommand.commanderSignature(), includesBackground: false)
        Self.expectFocusFlags(MoveCommand.commanderSignature(), includesBackground: false)
        Self.expectFocusFlags(DragCommand.commanderSignature(), includesBackground: false)
        Self.expectFocusFlags(PasteCommand.commanderSignature(), includesBackground: true)
        Self.expectFocusFlags(SetValueCommand.commanderSignature(), includesBackground: false)
        Self.expectFocusFlags(ActionCommand.commanderSignature(), includesBackground: false)
    }

    @Test
    @MainActor
    func `Removed spellings are rejected`() {
        #expect(throws: (any Error).self) { _ = try ClickCommand.parse(["--coords", "1,1"]) }
        #expect(throws: (any Error).self) { _ = try ClickCommand.parse(["--global-coords", "--at", "1,1"]) }
        #expect(throws: (any Error).self) { _ = try SeeCommand.parse(["--timeout-seconds", "2"]) }
        #expect(throws: (any Error).self) { _ = try PasteCommand.parse(["--restore-delay-ms", "0"]) }
        #expect(throws: (any Error).self) { _ = try TypeCommand.parse(["x", "--focus-timeout-seconds", "2"]) }
        #expect(throws: (any Error).self) { _ = try CaptureVideoCommand.parse(["a.mov", "--every-ms", "500"]) }
    }

    private static func expectFocusFlags(_ signature: CommandSignature, includesBackground: Bool) {
        var labels: Set<String> = []
        for flag in signature.flattened().flags {
            labels.insert(flag.label)
        }
        #expect(labels.contains("foreground"))
        #expect(labels.contains("noAutoFocus"))
        #expect(labels.contains("spaceSwitch"))
        #expect(labels.contains("bringToCurrentSpace"))
        #expect(labels.contains("focusBackground") == includesBackground)
        #expect(signature.flattened().options.contains { $0.label == "focusTimeout" })
    }
}
