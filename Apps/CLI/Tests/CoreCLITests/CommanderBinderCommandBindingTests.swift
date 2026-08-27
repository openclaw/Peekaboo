import Commander
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooCLI

struct CommanderBinderCommandBindingTests {
    @Test
    func `Clean command option + flag binding`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: ["olderThan": ["48"], "snapshot": ["ignored"]],
            flags: ["dryRun"]
        )
        var command = try CommanderCLIBinder.instantiateCommand(ofType: CleanCommand.self, parsedValues: parsed)
        #expect(command.dryRun == true)
        #expect(command.olderThan == 48)
        #expect(command.snapshot == "ignored")

        let allSnapshots = ParsedValues(positional: [], options: [:], flags: ["allSnapshots"])
        command = try CommanderCLIBinder.instantiateCommand(ofType: CleanCommand.self, parsedValues: allSnapshots)
        #expect(command.allSnapshots == true)
    }

    @Test
    func `Clipboard set subcommand binds only write options`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "filePath": ["/tmp/demo.txt"],
                "alsoText": ["Peekaboo clipboard file smoke"]
            ],
            flags: ["allowLarge", "verify"]
        )

        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: ClipboardCommand.SetSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.filePath == "/tmp/demo.txt")
        #expect(command.text == nil)
        #expect(command.alsoText == "Peekaboo clipboard file smoke")
        #expect(command.allowLarge == true)
        #expect(command.verify == true)
    }

    @Test
    func `Clipboard root exposes real subcommands and no action option`() {
        let description = ClipboardCommand.commandDescription
        var names: [String] = []
        for subcommand in description.subcommands {
            if let name = subcommand.commandDescription.commandName {
                names.append(name)
            }
        }
        #expect(names == ["get", "set", "clear", "save", "restore"])
        #expect(!CommandSignature.describe(ClipboardCommand()).flattened().options.contains { option in
            option.names.contains(.long("action"))
        })
    }

    @Test
    func `Image command binding`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "app": ["Safari"],
                "pid": ["123"],
                "path": ["/tmp/out.jpg"],
                "mode": ["screen"],
                "windowTitle": ["Inbox"],
                "windowIndex": ["2"],
                "screenIndex": ["1"],
                "format": ["jpg"],
                "analyze": ["describe"]
            ],
            flags: []
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: SeeCommand.self, parsedValues: parsed)
        #expect(command.app == "Safari")
        #expect(command.pid == 123)
        #expect(command.path == "/tmp/out.jpg")
        #expect(command.mode == .screen)
        #expect(command.windowTitle == "Inbox")
        #expect(command.windowIndex == 2)
        #expect(command.screenIndex == 1)
        #expect(command.format == .jpg)
        #expect(command.captureFocus == .background)
        #expect(command.analyze == "describe")
    }

    @Test
    func `Image command invalid mode`() {
        let parsed = ParsedValues(positional: [], options: ["mode": ["banana"]], flags: [])
        #expect(throws: CommanderBindingError.invalidArgument(
            label: "mode",
            value: "banana",
            reason: "Unknown value for CaptureMode"
        )) {
            _ = try CommanderCLIBinder.instantiateCommand(ofType: SeeCommand.self, parsedValues: parsed)
        }
    }

    @Test
    func `See infers format from path and rejects conflicts`() throws {
        let inferred = try CommanderCLIBinder.instantiateCommand(
            ofType: SeeCommand.self,
            parsedValues: ParsedValues(positional: [], options: ["path": ["/tmp/capture.jpg"]], flags: [])
        )
        #expect(inferred.format == .jpg)

        #expect(throws: CommanderBindingError.self) {
            _ = try CommanderCLIBinder.instantiateCommand(
                ofType: SeeCommand.self,
                parsedValues: ParsedValues(
                    positional: [],
                    options: ["path": ["/tmp/capture.png"], "format": ["jpg"]],
                    flags: []
                )
            )
        }
    }

    @Test
    func `See command binding`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "app": ["Safari"],
                "pid": ["4321"],
                "windowTitle": ["Inbox"],
                "mode": ["screen"],
                "path": ["/tmp/see.png"],
                "screenIndex": ["2"],
                "analyze": ["describe"],
                "depth": ["8"],
                "maxElements": ["500"],
                "maxChildren": ["100"]
            ],
            flags: ["annotate"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: SeeCommand.self, parsedValues: parsed)
        #expect(command.app == "Safari")
        #expect(command.pid == 4321)
        #expect(command.windowTitle == "Inbox")
        #expect(command.mode == .screen)
        #expect(command.path == "/tmp/see.png")
        #expect(command.screenIndex == 2)
        #expect(command.annotate == true)
        #expect(command.analyze == "describe")
        #expect(command.depth == 8)
        #expect(command.maxElements == 500)
        #expect(command.maxChildren == 100)
    }

    @Test
    func `App switch command binding with verify`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "to": ["Safari"],
            ],
            flags: ["verify", "foreground"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: AppCommand.SwitchSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.to == "Safari")
        #expect(command.verify == true)
        #expect(command.cycle == false)
        #expect(command.foreground == true)
    }

    @Test
    func `Window focus command binding with verify`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "app": ["Safari"],
                "snapshot": [SnapshotReferenceFixtures.first.rawValue],
            ],
            flags: ["verify"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: WindowCommand.FocusSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.verify == true)
        #expect(command.snapshot == SnapshotReferenceFixtures.first.rawValue)
    }

    @Test
    func `Dock launch command binding with verify`() throws {
        let parsed = ParsedValues(
            positional: ["Safari"],
            options: [:],
            flags: ["verify"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: DockCommand.LaunchSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.app == "Safari")
        #expect(command.verify == true)
    }

    @Test
    func `Tools command binding`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [:],
            flags: ["noSort"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: ToolsListSubcommand.self, parsedValues: parsed)
        #expect(command.noSort == true)
    }

    @Test
    func `Permissions status host selectors configure the runtime owner`() throws {
        let local = try CommanderCLIBinder.instantiateCommand(
            ofType: PermissionsCommand.StatusSubcommand.self,
            parsedValues: ParsedValues(positional: [], options: [:], flags: ["no-remote"])
        )
        #expect(local.noRemote)
        #expect(!local.runtimeOptions.preferRemote)
        #expect(local.runtimeOptions.remoteIsolationRequested)

        let socketPath = "/tmp/selected-permission-host.sock"
        let explicit = try CommanderCLIBinder.instantiateCommand(
            ofType: PermissionsCommand.StatusSubcommand.self,
            parsedValues: ParsedValues(
                positional: [],
                options: ["bridge-socket": [socketPath]],
                flags: []
            )
        )
        #expect(explicit.bridgeSocket == socketPath)
        #expect(explicit.runtimeOptions.preferRemote)
        #expect(explicit.runtimeOptions.bridgeSocketPath == socketPath)
    }

    @Test
    func `Permissions grant binding`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        _ = try CommanderCLIBinder.instantiateCommand(
            ofType: PermissionsCommand.GrantSubcommand.self,
            parsedValues: parsed
        )
    }

    @Test
    func `Window close binding populates identification options`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "app": ["Safari"],
                "pid": ["4321"],
                "windowTitle": ["Inbox"],
                "windowIndex": ["2"]
            ],
            flags: []
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: WindowCommand.CloseSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.windowOptions.app == "Safari")
        #expect(command.windowOptions.pid == 4321)
        #expect(command.windowOptions.windowTitle == "Inbox")
        #expect(command.windowOptions.windowIndex == 2)
    }

    @Test
    func `Window move binding handles coordinates`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "app": ["Safari"],
                "x": ["120"],
                "y": ["340"]
            ],
            flags: []
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: WindowCommand.MoveSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.windowOptions.app == "Safari")
        #expect(command.x == 120)
        #expect(command.y == 340)
    }

    @Test
    func `Window move requires coordinates`() {
        let parsed = ParsedValues(
            positional: [],
            options: ["app": ["Safari"], "x": ["50"]],
            flags: []
        )
        #expect(throws: CommanderBindingError.missingArgument(label: "y")) {
            _ = try CommanderCLIBinder.instantiateCommand(
                ofType: WindowCommand.MoveSubcommand.self,
                parsedValues: parsed
            )
        }
    }

    @Test
    func `Window focus binding maps focus options`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "app": ["Terminal"],
                "focusTimeout": ["5.5s"],
                "focusRetryCount": ["3"]
            ],
            flags: ["noAutoFocus", "spaceSwitch", "bringToCurrentSpace"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: WindowCommand.FocusSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.windowOptions.app == "Terminal")
        #expect(command.focusOptions.noAutoFocus == true)
        #expect(command.focusOptions.spaceSwitch == true)
        #expect(command.focusOptions.bringToCurrentSpace == true)
        #expect(command.focusOptions.focusTimeout == 5.5)
        #expect(command.focusOptions.focusRetryCount == 3)
    }

    @Test
    func `Window list binding`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "app": ["Finder"],
                "pid": ["999"]
            ],
            flags: ["groupBySpace"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: WindowCommand.WindowListSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.app == "Finder")
        #expect(command.pid == 999)
        #expect(command.groupBySpace == true)
    }

    @Test
    func `Click command binding`() throws {
        let parsed = ParsedValues(
            positional: ["Submit"],
            options: [
                "snapshot": [SnapshotReferenceFixtures.first.rawValue],
                "on": ["B1"],
                "app": ["Safari"],
                "waitFor": ["2500"],
                "inputStrategy": ["actionOnly"]
            ],
            flags: ["longPress", "noAutoFocus"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: ClickCommand.self, parsedValues: parsed)
        #expect(command.query == "Submit")
        #expect(command.snapshot == SnapshotReferenceFixtures.first.rawValue)
        #expect(command.on == "B1")
        #expect(command.target.app == "Safari")
        #expect(command.waitFor.roundedMilliseconds == 2500)
        #expect(command.longPress == true)
        #expect(command.focusOptions.noAutoFocus == true)
        #expect(command.runtimeOptions.inputStrategy == .actionOnly)
    }

    @Test
    func `Type command binding`() throws {
        let parsed = ParsedValues(
            positional: ["Hello"],
            options: [
                "snapshot": [SnapshotReferenceFixtures.second.rawValue],
                "delay": ["10"],
                "wpm": ["150"],
                "app": ["Notes"],
                "windowId": ["424242"],
                "focusTimeout": ["3.5s"]
            ],
            flags: ["clear", "spaceSwitch"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: TypeCommand.self, parsedValues: parsed)
        #expect(command.text == "Hello")
        #expect(command.snapshot == SnapshotReferenceFixtures.second.rawValue)
        #expect(command.delay.roundedMilliseconds == 10)
        #expect(command.profileOption == nil)
        #expect(command.wordsPerMinute == 150)
        #expect(command.clear == true)
        #expect(command.target.app == "Notes")
        #expect(command.target.windowId == 424_242)
        #expect(command.focusOptions.spaceSwitch == true)
        #expect(command.focusOptions.focusTimeout == 3.5)
    }

    @Test
    func `Type command binding with text option`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "text": ["OptionText"],
                "snapshot": [SnapshotReferenceFixtures.first.rawValue]
            ],
            flags: []
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: TypeCommand.self, parsedValues: parsed)
        #expect(command.text == nil)
        #expect(command.textOption == "OptionText")
        #expect(command.snapshot == SnapshotReferenceFixtures.first.rawValue)
    }

    @Test
    func `Set value command binding`() throws {
        let parsed = ParsedValues(
            positional: ["Hello"],
            options: [
                "on": ["T1"],
                "snapshot": [SnapshotReferenceFixtures.first.rawValue],
            ],
            flags: []
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: SetValueCommand.self, parsedValues: parsed)
        #expect(command.value == "Hello")
        #expect(command.on == "T1")
        #expect(command.snapshot == SnapshotReferenceFixtures.first.rawValue)
    }

    @Test
    func `Action command binding`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "on": ["B1"],
                "action": ["AXPress"],
                "snapshot": [SnapshotReferenceFixtures.first.rawValue],
            ],
            flags: []
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: ActionCommand.self, parsedValues: parsed)
        #expect(command.on == "B1")
        #expect(command.action == "AXPress")
        #expect(command.actionName == nil)
        #expect(command.snapshot == SnapshotReferenceFixtures.first.rawValue)
    }

    @Test
    func `Press command binding`() throws {
        let parsed = ParsedValues(
            positional: ["cmd+c", "Return"],
            options: [
                "count": ["3"],
                "delay": ["25"],
                "hold": ["75"],
                "snapshot": [SnapshotReferenceFixtures.third.rawValue]
            ],
            flags: ["noAutoFocus"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: PressCommand.self, parsedValues: parsed)
        #expect(command.chords == ["cmd+c", "Return"])
        #expect(command.count == 3)
        #expect(command.delay.roundedMilliseconds == 25)
        #expect(command.hold.roundedMilliseconds == 75)
        #expect(command.snapshot == SnapshotReferenceFixtures.third.rawValue)
        #expect(command.focusOptions.noAutoFocus == true)
    }

    @Test
    func `Capture video command binding`() throws {
        let parsed = ParsedValues(
            positional: ["/tmp/demo.mov"],
            options: [
                "sampleFps": ["2"],
                "start": ["1s"],
                "end": ["2s"],
                "maxFrames": ["123"],
                "maxMb": ["10"],
                "resolutionCap": ["720"],
                "diffStrategy": ["quality"],
                "diffBudget": ["50ms"],
                "path": ["/tmp/outdir"],
                "autoclean": ["900s"],
                "videoOut": ["/tmp/out.mp4"]
            ],
            flags: ["noDiff"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: CaptureVideoCommand.self,
            parsedValues: parsed
        )
        #expect(command.input == "/tmp/demo.mov")
        #expect(command.sampleFps == 2)
        #expect(command.every == nil)
        #expect(command.start?.roundedMilliseconds == 1000)
        #expect(command.end?.roundedMilliseconds == 2000)
        #expect(command.noDiff == true)
        #expect(command.maxFrames == 123)
        #expect(command.maxMb == 10)
        #expect(command.resolutionCap == 720)
        #expect(command.diffStrategy == "quality")
        #expect(command.diffBudget?.roundedMilliseconds == 50)
        #expect(command.path == "/tmp/outdir")
        #expect(command.autoclean?.seconds == 900)
        #expect(command.videoOut == "/tmp/out.mp4")
    }

    @Test
    func `Capture video commander signature exposes required input`() {
        let signature = CaptureVideoCommand.commanderSignature()
        let input = signature.arguments.first { $0.label == "input" }
        #expect(input?.isOptional == false)
        #expect(input?.help == "Input video file")
    }

    @Test
    func `Capture live commander signature includes capture-engine option`() {
        let signature = CaptureLiveCommand.commanderSignature()
        let captureEngineOption = signature.options.first { $0.label == "captureEngine" }
        #expect(captureEngineOption != nil)
        #expect(captureEngineOption?.names.contains(.long("capture-engine")) == true)
        let modeOption = signature.options.first { $0.label == "mode" }
        #expect(modeOption?.help?.contains("area") == true)
    }

    @Test
    func `Capture live command binding keeps capture engine`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "mode": ["area"],
                "region": ["0,0,320,240"],
                "captureEngine": ["modern"],
            ],
            flags: []
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: CaptureLiveCommand.self,
            parsedValues: parsed
        )
        #expect(command.mode == "area")
        #expect(command.region == "0,0,320,240")
        #expect(command.captureEngine == "modern")
    }

    @Test
    func `Capture video command requires input`() {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        #expect(throws: CommanderBindingError.missingArgument(label: "input")) {
            _ = try CommanderCLIBinder.instantiateCommand(
                ofType: CaptureVideoCommand.self,
                parsedValues: parsed
            )
        }
    }

    @Test
    func `Paste command binding (text + target)`() throws {
        let defaultCommand = try CommanderCLIBinder.instantiateCommand(
            ofType: PasteCommand.self,
            parsedValues: ParsedValues(positional: [], options: [:], flags: [])
        )
        #expect(defaultCommand.restoreDelay == nil)

        let parsed = ParsedValues(
            positional: ["Hello"],
            options: [
                "app": ["TextEdit"],
                "windowTitle": ["Untitled"],
                "restoreDelay": ["250ms"],
            ],
            flags: ["allowLarge"]
        )

        let command = try CommanderCLIBinder.instantiateCommand(ofType: PasteCommand.self, parsedValues: parsed)
        #expect(command.text == "Hello")
        #expect(command.textOption == nil)
        #expect(command.target.app == "TextEdit")
        #expect(command.target.windowTitle == "Untitled")
        #expect(command.restoreDelay?.roundedMilliseconds == 250)
        #expect(command.allowLarge == true)

        let restoreDelay = PasteCommand.commanderSignature().options.first { $0.label == "restoreDelay" }
        #expect(restoreDelay?.names.contains(.long("restore-delay")) == true)
    }

    @Test
    func `See command respects capture-engine option`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: ["captureEngine": ["classic"]],
            flags: []
        )

        let runtimeOptions = try CommanderCLIBinder.makeRuntimeOptions(from: parsed)
        #expect(runtimeOptions.captureEnginePreference == "classic")

        let captureEngine = SeeCommand.commanderSignature().options.first { $0.label == "captureEngine" }
        #expect(captureEngine?.help?.contains("selected host") == true)
        #expect(captureEngine?.help?.contains("--no-remote") == true)
    }

    @Test
    func `See command binds capture engine and timeout options`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "captureEngine": ["classic"],
                "timeout": ["7s"],
            ],
            flags: []
        )

        let command = try CommanderCLIBinder.instantiateCommand(ofType: SeeCommand.self, parsedValues: parsed)
        #expect(command.captureEngine == "classic")
        #expect(command.timeout?.seconds == 7)
        #expect(command.runtimeOptions.captureEnginePreference == "classic")
    }

    @Test
    func `Image command binds capture engine option`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: ["captureEngine": ["modern"]],
            flags: []
        )

        let command = try CommanderCLIBinder.instantiateCommand(ofType: SeeCommand.self, parsedValues: parsed)
        #expect(command.captureEngine == "modern")
        #expect(command.runtimeOptions.captureEnginePreference == "modern")
    }

    @Test
    func `Image command mode help lists all supported modes`() {
        let signature = SeeCommand.commanderSignature()
        let modeOption = signature.options.first { $0.label == "mode" }
        #expect(modeOption?.help?.contains("multi") == true)
        #expect(modeOption?.help?.contains("area") == true)
    }

    @Test
    func `Move command binding with --at`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "at": ["100,200"],
                "duration": ["750"],
                "steps": ["30"],
                "profile": ["human"],
                "snapshot": [SnapshotReferenceFixtures.first.rawValue]
            ],
            flags: ["smooth", "foreground"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: MoveCommand.self, parsedValues: parsed)
        #expect(command.at == "100,200")
        #expect(command.duration?.roundedMilliseconds == 750)
        #expect(command.steps == 30)
        #expect(command.profile == "human")
        #expect(command.snapshot == SnapshotReferenceFixtures.first.rawValue)
        #expect(command.smooth == true)
        #expect(command.focusOptions.foreground)
    }

    @Test
    func `Move command binding with --on`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "on": ["B1"],
                "snapshot": [SnapshotReferenceFixtures.first.rawValue]
            ],
            flags: []
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: MoveCommand.self, parsedValues: parsed)
        #expect(command.on == "B1")
        #expect(command.snapshot == SnapshotReferenceFixtures.first.rawValue)
    }

    @Test
    func `Move command requires a target (validation)`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        var command = try CommanderCLIBinder.instantiateCommand(ofType: MoveCommand.self, parsedValues: parsed)
        #expect(throws: ValidationError.self) {
            try command.validate()
        }
    }

    @Test
    func `Move command rejects conflicting targets`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: ["at": ["100,200"], "on": ["B1"]],
            flags: ["foreground"]
        )
        var command = try CommanderCLIBinder.instantiateCommand(ofType: MoveCommand.self, parsedValues: parsed)
        #expect(throws: ValidationError.self) {
            try command.validate()
        }
    }

    @Test
    func `Drag command binding`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "from": ["B1"],
                "to": ["T2"],
                "duration": ["1200"],
                "steps": ["15"],
                "modifiers": ["cmd,shift"],
                "profile": ["human"],
                "snapshot": [SnapshotReferenceFixtures.second.rawValue]
            ],
            flags: ["spaceSwitch", "foreground"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: DragCommand.self, parsedValues: parsed)
        #expect(command.from == "B1")
        #expect(command.to == "T2")
        #expect(command.duration?.roundedMilliseconds == 1200)
        #expect(command.steps == 15)
        #expect(command.modifiers?.description == "cmd,shift")
        #expect(command.profile == "human")
        #expect(command.snapshot == SnapshotReferenceFixtures.second.rawValue)
        #expect(command.focusOptions.spaceSwitch == true)
        #expect(command.focusOptions.foreground)
    }
}
