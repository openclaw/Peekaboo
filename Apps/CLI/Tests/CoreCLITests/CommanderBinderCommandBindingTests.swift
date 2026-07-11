import Commander
import Testing
@testable import PeekabooCLI

struct CommanderBinderCommandBindingTests {
    @Test
    func `Sleep command duration binding`() throws {
        let parsed = ParsedValues(positional: ["2500"], options: [:], flags: [])
        let command = try CommanderCLIBinder.instantiateCommand(ofType: SleepCommand.self, parsedValues: parsed)
        #expect(command.duration == 2500)
    }

    @Test
    func `Sleep command binding errors`() {
        let missing = ParsedValues(positional: [], options: [:], flags: [])
        #expect(throws: CommanderBindingError.missingArgument(label: "duration")) {
            _ = try CommanderCLIBinder.instantiateCommand(ofType: SleepCommand.self, parsedValues: missing)
        }

        let invalid = ParsedValues(positional: ["abc"], options: [:], flags: [])
        #expect(throws: CommanderBindingError.invalidArgument(
            label: "duration",
            value: "abc",
            reason: "Unable to parse Int"
        )) {
            _ = try CommanderCLIBinder.instantiateCommand(ofType: SleepCommand.self, parsedValues: invalid)
        }
    }

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
    func `Run command binding`() throws {
        let parsed = ParsedValues(
            positional: ["/tmp/demo.peekaboo.json"],
            options: ["output": ["/tmp/result.json"]],
            flags: ["noFailFast"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: RunCommand.self, parsedValues: parsed)
        #expect(command.scriptPath == "/tmp/demo.peekaboo.json")
        #expect(command.output == "/tmp/result.json")
        #expect(command.noFailFast == true)
    }

    @Test
    func `Run command requires script path`() {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        #expect(throws: CommanderBindingError.missingArgument(label: "scriptPath")) {
            _ = try CommanderCLIBinder.instantiateCommand(ofType: RunCommand.self, parsedValues: parsed)
        }
    }

    @Test
    func `Clipboard command binding with file-path and also-text`() throws {
        let parsed = ParsedValues(
            positional: ["set"],
            options: [
                "filePath": ["/tmp/demo.txt"],
                "alsoText": ["Peekaboo clipboard file smoke"]
            ],
            flags: ["allowLarge", "verify"]
        )

        let command = try CommanderCLIBinder.instantiateCommand(ofType: ClipboardCommand.self, parsedValues: parsed)
        #expect(command.action == "set")
        #expect(command.actionOption == nil)
        #expect(command.filePath == "/tmp/demo.txt")
        #expect(command.imagePath == nil)
        #expect(command.text == nil)
        #expect(command.alsoText == "Peekaboo clipboard file smoke")
        #expect(command.allowLarge == true)
        #expect(command.verify == true)
    }

    @Test
    func `Clipboard command keeps action option alias`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "actionOption": ["get"]
            ],
            flags: []
        )

        let command = try CommanderCLIBinder.instantiateCommand(ofType: ClipboardCommand.self, parsedValues: parsed)
        #expect(command.action == nil)
        #expect(command.actionOption == "get")
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
                "captureFocus": ["foreground"],
                "analyze": ["describe"]
            ],
            flags: []
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: ImageCommand.self, parsedValues: parsed)
        #expect(command.app == "Safari")
        #expect(command.pid == 123)
        #expect(command.path == "/tmp/out.jpg")
        #expect(command.mode == .screen)
        #expect(command.windowTitle == "Inbox")
        #expect(command.windowIndex == 2)
        #expect(command.screenIndex == 1)
        #expect(command.format == .jpg)
        #expect(command.captureFocus == .foreground)
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
            _ = try CommanderCLIBinder.instantiateCommand(ofType: ImageCommand.self, parsedValues: parsed)
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
                "analyze": ["describe"]
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
    }

    @Test
    func `App switch command binding with verify`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "to": ["Safari"],
            ],
            flags: ["verify"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: AppCommand.SwitchSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.to == "Safari")
        #expect(command.verify == true)
        #expect(command.cycle == false)
    }

    @Test
    func `Window focus command binding with verify`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "app": ["Safari"],
                "snapshot": ["snapshot-123"],
            ],
            flags: ["verify"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: WindowCommand.FocusSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.verify == true)
        #expect(command.snapshot == "snapshot-123")
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
        let command = try CommanderCLIBinder.instantiateCommand(ofType: ToolsCommand.self, parsedValues: parsed)
        #expect(command.noSort == true)
    }

    @Test
    func `List menubar binding`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        _ = try CommanderCLIBinder.instantiateCommand(ofType: ListCommand.MenuBarSubcommand.self, parsedValues: parsed)
    }

    @Test
    func `List windows binding`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "app": ["Safari"],
                "pid": ["123"],
                "includeDetails": ["bounds,ids"]
            ],
            flags: []
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: ListCommand.WindowsSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.app == "Safari")
        #expect(command.pid == 123)
        #expect(command.includeDetails == "bounds,ids")
    }

    @Test
    func `List windows requires app`() {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        #expect(throws: CommanderBindingError.missingArgument(label: "app")) {
            _ = try CommanderCLIBinder.instantiateCommand(
                ofType: ListCommand.WindowsSubcommand.self,
                parsedValues: parsed
            )
        }
    }

    @Test
    func `List windows binding accepts pid without app`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: ["pid": ["123"]],
            flags: []
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: ListCommand.WindowsSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.app == nil)
        #expect(command.pid == 123)
    }

    @Test
    func `Permissions status binding`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        _ = try CommanderCLIBinder.instantiateCommand(
            ofType: PermissionsCommand.StatusSubcommand.self,
            parsedValues: parsed
        )
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
                "focusTimeoutSeconds": ["5.5"],
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
        #expect(command.focusOptions.focusTimeoutSeconds == 5.5)
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
            flags: []
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: WindowCommand.WindowListSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.app == "Finder")
        #expect(command.pid == 999)
    }

    @Test
    func `Click command binding`() throws {
        let parsed = ParsedValues(
            positional: ["Submit"],
            options: [
                "snapshot": ["abc"],
                "on": ["B1"],
                "app": ["Safari"],
                "waitFor": ["2500"],
                "inputStrategy": ["actionOnly"]
            ],
            flags: ["longPress", "noAutoFocus"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: ClickCommand.self, parsedValues: parsed)
        #expect(command.query == "Submit")
        #expect(command.snapshot == "abc")
        #expect(command.on == "B1")
        #expect(command.target.app == "Safari")
        #expect(command.waitFor == 2500)
        #expect(command.longPress == true)
        #expect(command.focusOptions.noAutoFocus == true)
        #expect(command.runtimeOptions.inputStrategy == .actionOnly)
    }

    @Test
    func `Type command binding`() throws {
        let parsed = ParsedValues(
            positional: ["Hello"],
            options: [
                "snapshot": ["xyz"],
                "delay": ["10"],
                "wpm": ["150"],
                "tab": ["2"],
                "app": ["Notes"],
                "windowId": ["424242"],
                "focusTimeoutSeconds": ["3.5"]
            ],
            flags: ["pressReturn", "escape", "delete", "clear", "spaceSwitch"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: TypeCommand.self, parsedValues: parsed)
        #expect(command.text == "Hello")
        #expect(command.snapshot == "xyz")
        #expect(command.delay == 10)
        #expect(command.profileOption == nil)
        #expect(command.wordsPerMinute == 150)
        #expect(command.tab == 2)
        #expect(command.pressReturn == true)
        #expect(command.escape == true)
        #expect(command.delete == true)
        #expect(command.clear == true)
        #expect(command.target.app == "Notes")
        #expect(command.target.windowId == 424_242)
        #expect(command.focusOptions.spaceSwitch == true)
        #expect(command.focusOptions.focusTimeoutSeconds == 3.5)
    }

    @Test
    func `Type command binding with text option`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "text": ["OptionText"],
                "snapshot": ["abc"]
            ],
            flags: []
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: TypeCommand.self, parsedValues: parsed)
        #expect(command.text == nil)
        #expect(command.textOption == "OptionText")
        #expect(command.snapshot == "abc")
    }

    @Test
    func `Set value command binding`() throws {
        let parsed = ParsedValues(
            positional: ["Hello"],
            options: [
                "on": ["T1"],
                "snapshot": ["abc"],
            ],
            flags: []
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: SetValueCommand.self, parsedValues: parsed)
        #expect(command.value == "Hello")
        #expect(command.on == "T1")
        #expect(command.snapshot == "abc")
    }

    @Test
    func `Perform action command binding`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "on": ["B1"],
                "action": ["AXPress"],
                "snapshot": ["abc"],
            ],
            flags: []
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: PerformActionCommand.self, parsedValues: parsed)
        #expect(command.on == "B1")
        #expect(command.action == "AXPress")
        #expect(command.snapshot == "abc")
    }

    @Test
    func `Press command binding`() throws {
        let parsed = ParsedValues(
            positional: ["cmd", "c"],
            options: [
                "count": ["3"],
                "delay": ["25"],
                "hold": ["75"],
                "snapshot": ["sess-123"]
            ],
            flags: ["noAutoFocus"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: PressCommand.self, parsedValues: parsed)
        #expect(command.keys == ["cmd", "c"])
        #expect(command.count == 3)
        #expect(command.delay == 25)
        #expect(command.hold == 75)
        #expect(command.snapshot == "sess-123")
        #expect(command.focusOptions.noAutoFocus == true)
    }

    @Test
    func `Capture video command binding`() throws {
        let parsed = ParsedValues(
            positional: ["/tmp/demo.mov"],
            options: [
                "sampleFps": ["2"],
                "startMs": ["1000"],
                "endMs": ["2000"],
                "maxFrames": ["123"],
                "maxMb": ["10"],
                "resolutionCap": ["720"],
                "diffStrategy": ["quality"],
                "diffBudgetMs": ["50"],
                "path": ["/tmp/outdir"],
                "autocleanMinutes": ["15"],
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
        #expect(command.everyMs == nil)
        #expect(command.startMs == 1000)
        #expect(command.endMs == 2000)
        #expect(command.noDiff == true)
        #expect(command.maxFrames == 123)
        #expect(command.maxMb == 10)
        #expect(command.resolutionCap == 720)
        #expect(command.diffStrategy == "quality")
        #expect(command.diffBudgetMs == 50)
        #expect(command.path == "/tmp/outdir")
        #expect(command.autocleanMinutes == 15)
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
    func `Hotkey command binding (positional wins)`() throws {
        let parsed = ParsedValues(
            positional: ["cmd,space"],
            options: ["keys": ["cmd,c"], "holdDuration": ["120"]],
            flags: ["focusBackground"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: HotkeyCommand.self, parsedValues: parsed)
        #expect(command.resolvedKeys == "cmd,space")
        #expect(command.holdDuration == 120)
        #expect(command.focusOptions.focusBackground)
        #expect(command.focusOptions.autoFocus == true)
    }

    @Test
    func `Hotkey command requires keys`() {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        #expect(throws: ValidationError.self) {
            _ = try CommanderCLIBinder.instantiateCommand(ofType: HotkeyCommand.self, parsedValues: parsed)
        }
    }

    @Test
    func `Paste command binding (text + target)`() throws {
        let defaultCommand = try CommanderCLIBinder.instantiateCommand(
            ofType: PasteCommand.self,
            parsedValues: ParsedValues(positional: [], options: [:], flags: [])
        )
        #expect(defaultCommand.restoreDelayMs == nil)

        let parsed = ParsedValues(
            positional: ["Hello"],
            options: [
                "app": ["TextEdit"],
                "windowTitle": ["Untitled"],
                "restoreDelayMs": ["250"],
            ],
            flags: ["allowLarge"]
        )

        let command = try CommanderCLIBinder.instantiateCommand(ofType: PasteCommand.self, parsedValues: parsed)
        #expect(command.text == "Hello")
        #expect(command.textOption == nil)
        #expect(command.target.app == "TextEdit")
        #expect(command.target.windowTitle == "Untitled")
        #expect(command.restoreDelayMs == 250)
        #expect(command.allowLarge == true)

        let restoreDelay = PasteCommand.commanderSignature().options.first { $0.label == "restoreDelayMs" }
        #expect(restoreDelay?.help?.contains("default: 150") == true)
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
    }

    @Test
    func `See command binds capture engine and timeout options`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "captureEngine": ["classic"],
                "timeoutSeconds": ["7"],
            ],
            flags: []
        )

        let command = try CommanderCLIBinder.instantiateCommand(ofType: SeeCommand.self, parsedValues: parsed)
        #expect(command.captureEngine == "classic")
        #expect(command.timeoutSeconds == 7)
        #expect(command.runtimeOptions.captureEnginePreference == "classic")
    }

    @Test
    func `Image command binds capture engine option`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: ["captureEngine": ["modern"]],
            flags: []
        )

        let command = try CommanderCLIBinder.instantiateCommand(ofType: ImageCommand.self, parsedValues: parsed)
        #expect(command.captureEngine == "modern")
        #expect(command.runtimeOptions.captureEnginePreference == "modern")
    }

    @Test
    func `Image command mode help lists all supported modes`() {
        let signature = ImageCommand.commanderSignature()
        let modeOption = signature.options.first { $0.label == "mode" }
        #expect(modeOption?.help?.contains("multi") == true)
        #expect(modeOption?.help?.contains("area") == true)
    }

    @Test
    func `Move command binding with coordinates`() throws {
        let parsed = ParsedValues(
            positional: ["100,200"],
            options: [
                "duration": ["750"],
                "steps": ["30"],
                "profile": ["human"],
                "snapshot": ["sess-1"]
            ],
            flags: ["smooth"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: MoveCommand.self, parsedValues: parsed)
        #expect(command.coordinates == "100,200")
        #expect(command.duration == 750)
        #expect(command.steps == 30)
        #expect(command.profile == "human")
        #expect(command.snapshot == "sess-1")
        #expect(command.smooth == true)
    }

    @Test
    func `Move command binding with --coords`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "coords": ["100,200"],
                "duration": ["750"],
                "steps": ["30"],
                "profile": ["human"],
                "snapshot": ["sess-1"]
            ],
            flags: ["smooth"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: MoveCommand.self, parsedValues: parsed)
        #expect(command.coords == "100,200")
        #expect(command.coordinates == nil)
        #expect(command.duration == 750)
        #expect(command.steps == 30)
        #expect(command.profile == "human")
        #expect(command.snapshot == "sess-1")
        #expect(command.smooth == true)
    }

    @Test
    func `Move command binding with --on`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "on": ["B1"],
                "snapshot": ["sess-1"]
            ],
            flags: []
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: MoveCommand.self, parsedValues: parsed)
        #expect(command.on == "B1")
        #expect(command.id == nil)
        #expect(command.snapshot == "sess-1")
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
        let parsed = ParsedValues(positional: ["100,200"], options: [:], flags: ["center"])
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
                "snapshot": ["sess-drag"]
            ],
            flags: ["spaceSwitch"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: DragCommand.self, parsedValues: parsed)
        #expect(command.from == "B1")
        #expect(command.to == "T2")
        #expect(command.duration == 1200)
        #expect(command.steps == 15)
        #expect(command.modifiers == "cmd,shift")
        #expect(command.profile == "human")
        #expect(command.snapshot == "sess-drag")
        #expect(command.focusOptions.spaceSwitch == true)
    }

    @Test
    func `Swipe command binding`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "fromCoords": ["10,20"],
                "toCoords": ["30,40"],
                "duration": ["900"],
                "steps": ["25"],
                "profile": ["linear"],
                "snapshot": ["sess-swipe"]
            ],
            flags: []
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: SwipeCommand.self, parsedValues: parsed)
        #expect(command.fromCoords == "10,20")
        #expect(command.toCoords == "30,40")
        #expect(command.duration == 900)
        #expect(command.steps == 25)
        #expect(command.profile == "linear")
        #expect(command.snapshot == "sess-swipe")
    }

    @Test
    func `Swipe command requires from/to`() async throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        var command = try CommanderCLIBinder.instantiateCommand(ofType: SwipeCommand.self, parsedValues: parsed)
        await #expect(throws: ExitCode.self) {
            try await command.run(using: CommandRuntime.makeDefault())
        }
    }
}
