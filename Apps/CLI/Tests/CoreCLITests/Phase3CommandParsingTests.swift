import Commander
import CoreGraphics
import PeekabooAutomationKit
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooCLI

@Suite(.tags(.fast))
@MainActor
struct Phase3CommandParsingTests {
    @Test
    func `Press parses xdotool chords and sequences`() throws {
        var command = try PressCommand.parse(["--foreground", "cmd+shift+t", "Return"])
        let chords = try command.parsedChords()

        #expect(command.chords == ["cmd+shift+t", "Return"])
        #expect(chords.map(\.serviceKeys) == ["cmd,shift,t", "return"])
        try command.validate()

        var extended = try PressCommand.parse(["--foreground", "forward_delete", "cmd+,", "Home"])
        #expect(try extended.parsedChords().map(\.serviceKeys) == ["forwarddelete", "cmd,comma", "home"])
        try extended.validate()
    }

    @Test
    func `Press rejects invalid and removed chord syntax`() throws {
        for value in ["cmd+shift", "cmd+c+v", "cmd++c", "cmd,c", "cmd c", "notakey"] {
            var command = try PressCommand.parse([value])
            #expect(throws: ValidationError.self) {
                try command.validate()
            }
        }
    }

    @Test
    func `Drag distinguishes coordinates from element IDs`() throws {
        let command = try DragCommand.parse([
            "--from", "100,200",
            "--to", "B7",
            "--button", "right",
            "--foreground",
        ])

        #expect(command.splitTarget(command.from).coordinates == "100,200")
        #expect(command.splitTarget(command.from).element == nil)
        #expect(command.splitTarget(command.to).element == "B7")
        #expect(command.splitTarget(command.to).coordinates == nil)
        #expect(command.resolvedButton == .right)
    }

    @Test
    func `See parses merged pixel and tree options`() throws {
        let pixels = try SeeCommand.parse([
            "--region", "10,20,300,400",
            "--format", "jpg",
            "--retina",
            "--no-elements",
        ])
        #expect(pixels.region == "10,20,300,400")
        #expect(pixels.format == .jpg)
        #expect(pixels.retina)
        #expect(pixels.noElements)

        let inferredScreen = try SeeCommand.parse(["--screen-index", "2", "--no-elements"])
        #expect(inferredScreen.determineMode() == .screen)

        let stdout = try SeeCommand.parse(["--path", "-"])
        #expect(stdout.usesPixelOnlyCapture)

        let indexedWindow = try SeeCommand.parse(["--app", "TextEdit", "--window-index", "2"])
        #expect(try indexedWindow.observationTargetForCaptureWithDetectionIfPossible() ==
            .app(identifier: "TextEdit", window: .index(2)))

        let roi = try SeeCommand.parse(["--window-id", "42", "--roi", "10,20,300,200"])
        try roi.validateMergedOptions()
        let parsedROI = try #require(try roi.captureROI())
        #expect(parsedROI.bounds == CGRect(x: 10, y: 20, width: 300, height: 200))
        let observationROI = try #require(try roi.makeObservationRequest(target: .windowID(42)).capture.roi)
        #expect(observationROI.bounds == CGRect(x: 10, y: 20, width: 300, height: 200))

        let tree = try SeeCommand.parse([
            "--tree",
            "--no-screenshot",
            "--depth", "7",
            "--max-elements", "200",
            "--max-children", "25",
        ])
        #expect(tree.tree)
        #expect(tree.noScreenshot)
        #expect(tree.depth == 7)
        #expect(tree.maxElements == 200)
        #expect(tree.maxChildren == 25)

        for arguments in [
            ["--tree", "--no-screenshot", "--mode", "multi"],
            ["--tree", "--no-screenshot", "--region", "0,0,100,100"],
            ["--tree", "--no-screenshot", "--mode", "screen"],
            ["--tree", "--no-screenshot", "--screen-index", "1"],
            ["--tree", "--no-screenshot", "--app", "menubar"],
            ["--mode", "area", "--region", "0,0,100,100", "--annotate"],
            ["--mode", "multi", "--tree"],
            ["--menubar", "--no-elements"],
            ["--tree", "--no-screenshot", "--app", "TextEdit", "--window-id", "1", "--window-index", "0"],
            ["--no-elements", "--app", "frontmost", "--window-id", "42"],
            ["--no-elements", "--app", "frontmost", "--mode", "area", "--region", "0,0,100,100"],
            ["--no-elements", "--app", "frontmost", "--pid", "123"],
            ["--no-elements", "--app", "menubar", "--screen-index", "1"],
            ["--app", "frontmost", "--menubar"],
            ["--no-elements", "--mode", "screen", "--window-id", "42"],
            ["--no-elements", "--mode", "screen", "--app", "Safari"],
            ["--no-elements", "--mode", "area", "--region", "0,0,100,100", "--screen-index", "1"],
            ["--no-elements", "--mode", "multi", "--window-title", "Document", "--app", "TextEdit"],
            ["--no-elements", "--mode", "frontmost", "--pid", "123"],
            ["--path", "-", "--tree"],
            ["--window-id", "0"],
            ["--window-id", "4294967296"],
            ["--roi", "0,0,100,100"],
            ["--window-id", "42", "--roi", "0,0,100,100", "--no-elements"],
            ["--window-id", "42", "--roi", "0,0,100,100", "--no-screenshot", "--tree"],
            ["--window-id", "42", "--roi", "0,0,100,100", "--path", "-"],
        ] {
            let invalid = try SeeCommand.parse(arguments)
            #expect(throws: ValidationError.self) {
                try invalid.validateMergedOptions()
            }
        }

        let invalidROI = try SeeCommand.parse(["--window-id", "42", "--roi", "0,0,0,100"])
        #expect(throws: ValidationError.self) {
            try invalidROI.validateMergedOptions()
        }
    }

    @Test
    func `Action accepts positional and option forms with shared targeting`() throws {
        let positional = try ActionCommand.parse([
            "AXPress", "--on", "B7", "--app", "TextEdit", "--window-title", "Document",
        ])
        #expect(positional.actionName == "AXPress")
        #expect(positional.action == nil)
        #expect(positional.target.app == "TextEdit")
        #expect(positional.target.windowTitle == "Document")

        let option = try ActionCommand.parse(["--action", "AXIncrement", "--on", "S1", "--pid", "42"])
        #expect(option.actionName == nil)
        #expect(option.action == "AXIncrement")
        #expect(option.target.pid == 42)

        let padded = try ActionCommand.parse([" AXPress ", "--on", "B7"])
        #expect(try padded.requireAction() == "AXPress")
    }

    @Test
    func `Click parser delegates nested option groups to Commander`() throws {
        let command = try ClickCommand.parse([
            "Submit",
            "--snapshot", SnapshotReferenceFixtures.first.rawValue,
            "--window-id", "42",
            "--foreground",
            "--focus-timeout", "750",
            "--focus-retry-count", "3",
            "--json",
            "--input-strategy", "actionOnly",
        ])

        #expect(command.query == "Submit")
        #expect(command.snapshot == SnapshotReferenceFixtures.first.rawValue)
        #expect(command.target.windowId == 42)
        #expect(command.focusOptions.foreground)
        #expect(command.focusOptions.focusTimeoutDuration == .milliseconds(750))
        #expect(command.focusOptions.focusRetryCount == 3)
        #expect(command.jsonOutput)
        #expect(command.runtimeOptions.inputStrategy == .actionOnly)
    }

    @Test
    func `Direct element actions focus and web press only with explicit foreground`() throws {
        let targetArguments = [
            ["--app", "TextEdit"],
            ["--pid", "4242"],
            ["--window-id", "7373"],
        ]

        for arguments in targetArguments {
            let backgroundAction = try ActionCommand.parse(
                ["AXPress", "--on", "B7"] + arguments
            )
            let foregroundAction = try ActionCommand.parse(
                ["AXPress", "--on", "B7"] + arguments + ["--foreground"]
            )
            let backgroundSetValue = try SetValueCommand.parse(
                ["hello", "--on", "T1"] + arguments
            )
            let foregroundSetValue = try SetValueCommand.parse(
                ["hello", "--on", "T1"] + arguments + ["--foreground"]
            )

            for command in [
                (backgroundAction.target, backgroundAction.focusOptions),
                (backgroundSetValue.target, backgroundSetValue.focusOptions),
            ] {
                #expect(!ElementActionCommandExecutor.shouldFocus(
                    target: command.0,
                    focusOptions: command.1
                ))
                #expect(!ElementActionCommandExecutor.shouldAllowWebFocusFallback(
                    focusOptions: command.1
                ))
            }

            for command in [
                (foregroundAction.target, foregroundAction.focusOptions),
                (foregroundSetValue.target, foregroundSetValue.focusOptions),
            ] {
                #expect(ElementActionCommandExecutor.shouldFocus(
                    target: command.0,
                    focusOptions: command.1
                ))
                #expect(ElementActionCommandExecutor.shouldAllowWebFocusFallback(
                    focusOptions: command.1
                ))
            }
        }
    }

    @Test
    func `Explicit foreground respects no auto focus for direct element actions`() throws {
        let command = try ActionCommand.parse([
            "AXPress", "--on", "B7", "--app", "TextEdit", "--foreground", "--no-auto-focus",
        ])

        #expect(!ElementActionCommandExecutor.shouldFocus(
            target: command.target,
            focusOptions: command.focusOptions
        ))
        #expect(!ElementActionCommandExecutor.shouldAllowWebFocusFallback(
            focusOptions: command.focusOptions
        ))
    }

    @Test
    func `Removed root commands are unknown`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        for command in ["hotkey", "swipe", "image", "inspect-ui", "perform-action"] {
            #expect(throws: (any Error).self) {
                _ = try program.resolve(argv: ["peekaboo", command])
            }
        }
    }

    @Test
    func `Type rejects removed key flags`() {
        for flag in ["--return", "--tab", "--escape", "--delete"] {
            #expect(throws: (any Error).self) {
                _ = try TypeCommand.parse(["hello", flag])
            }
        }
    }
}
