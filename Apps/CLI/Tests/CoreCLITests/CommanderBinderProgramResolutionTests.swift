import Commander
import Testing
@testable import PeekabooCLI

struct CommanderBinderProgramResolutionTests {
    @Test
    @MainActor
    func `Commander program resolves image command options`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "image",
            "--app", "Safari",
            "--window-title", "Inbox",
            "--mode", "screen",
            "--capture-engine", "cg",
            "--path", "/tmp/sample.png"
        ])
        let values = invocation.parsedValues
        #expect(values.options["app"] == ["Safari"])
        #expect(values.options["windowTitle"] == ["Inbox"])
        #expect(values.options["mode"] == ["screen"])
        #expect(values.options["captureEngine"] == ["cg"])
        #expect(values.options["path"] == ["/tmp/sample.png"])
    }

    @Test
    @MainActor
    func `Commander program resolves see command flags`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "see",
            "--app", "Mail",
            "--annotate",
            "--screen-index", "1",
            "--analyze", "describe"
        ])
        let values = invocation.parsedValues
        #expect(values.options["app"] == ["Mail"])
        #expect(values.options["screenIndex"] == ["1"])
        #expect(values.options["analyze"] == ["describe"])
        #expect(values.flags.contains("annotate"))
    }

    @Test
    @MainActor
    func `Commander program resolves list windows options`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "list",
            "windows",
            "--app", "Safari",
            "--include-details", "ids,bounds"
        ])
        let values = invocation.parsedValues
        #expect(values.options["app"] == ["Safari"])
        #expect(values.options["includeDetails"] == ["ids,bounds"])
    }

    @Test
    @MainActor
    func `Commander program resolves browser command`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "browser",
            "navigate",
            "--url", "https://example.com",
            "--timeout", "5000",
            "--json",
        ])
        let values = invocation.parsedValues
        #expect(invocation.path == ["browser"])
        #expect(values.positional == ["navigate"])
        #expect(values.options["url"] == ["https://example.com"])
        #expect(values.options["timeout"] == ["5000"])
        #expect(values.flags.contains("jsonOutput"))
    }

    @Test
    @MainActor
    func `Commander program resolves inspect UI command`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "inspect-ui",
            "--app", "TextEdit",
            "--max-elements", "200",
        ])
        let values = invocation.parsedValues
        #expect(invocation.path == ["inspect-ui"])
        #expect(values.options["app"] == ["TextEdit"])
        #expect(values.options["maxElements"] == ["200"])
    }

    @Test
    @MainActor
    func `Commander program preserves inspect UI app target alias`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "inspect-ui",
            "--app-target", "TextEdit",
        ])
        #expect(invocation.parsedValues.options["appTarget"] == ["TextEdit"])
    }

    @Test
    @MainActor
    func `Commander program resolves capture action command tail`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "capture",
            "action",
            "--duration-limit", "3",
            "--",
            "echo",
            "hello",
            "--flag",
        ])
        let values = invocation.parsedValues
        #expect(invocation.path == ["capture", "action"])
        #expect(values.options["durationLimit"] == ["3"])
        #expect(values.options["command"] == ["echo", "hello", "--flag"])
    }

    @Test
    @MainActor
    func `Commander router resolves agent permission alias before task argument`() throws {
        let invocation = try CommanderRuntimeRouter.resolve(argv: [
            "peekaboo",
            "agent",
            "permission",
            "status",
            "--json",
        ])

        #expect(invocation.metadata.name == "status")
        #expect(String(reflecting: invocation.type).contains("PermissionCommand.StatusSubcommand"))
        #expect(invocation.parsedValues.flags.contains("jsonOutput"))
        #expect(invocation.parsedValues.positional.isEmpty)
    }

    @Test
    @MainActor
    func `Commander program keeps natural-language agent tasks positional`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "agent",
            "list files",
            "--dry-run",
        ])

        #expect(invocation.path == ["agent"])
        #expect(invocation.parsedValues.positional == ["list files"])
        #expect(invocation.parsedValues.flags.contains("dryRun"))
    }

    @Test
    @MainActor
    func `Commander program resolves click options and focus flags`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "click",
            "\"Submit\"",
            "--snapshot", "abc",
            "--on", "B1",
            "--app", "Safari",
            "--wait-for", "2500",
            "--no-auto-focus",
            "--space-switch"
        ])
        let values = invocation.parsedValues
        #expect(values.positional == ["\"Submit\""])
        #expect(values.options["snapshot"] == ["abc"])
        #expect(values.options["on"] == ["B1"])
        #expect(values.options["app"] == ["Safari"])
        #expect(values.options["waitFor"] == ["2500"])
        #expect(values.flags.contains("noAutoFocus"))
        #expect(values.flags.contains("spaceSwitch"))
    }

    @Test
    @MainActor
    func `Commander program resolves hotkey background focus flag`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "hotkey",
            "cmd,l",
            "--app", "Safari",
            "--focus-background"
        ])
        let values = invocation.parsedValues
        #expect(values.positional == ["cmd,l"])
        #expect(values.options["app"] == ["Safari"])
        #expect(values.flags.contains("focusBackground"))
    }

    @Test
    @MainActor
    func `Commander program resolves click background focus flag`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "click",
            "--coords", "10,10",
            "--app", "Safari",
            "--focus-background"
        ])
        let values = invocation.parsedValues
        #expect(values.options["coords"] == ["10,10"])
        #expect(values.options["app"] == ["Safari"])
        #expect(values.flags.contains("focusBackground"))
    }

    @Test
    @MainActor
    func `Commander program resolves type command options`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "type",
            "Hello",
            "--snapshot", "xyz",
            "--delay", "10",
            "--tab", "2",
            "--return",
            "--escape",
            "--delete",
            "--clear",
            "--app", "Notes",
            "--focus-timeout-seconds", "3.5",
            "--space-switch"
        ])
        let values = invocation.parsedValues
        #expect(values.positional == ["Hello"])
        #expect(values.options["snapshot"] == ["xyz"])
        #expect(values.options["delay"] == ["10"])
        #expect(values.options["tab"] == ["2"])
        #expect(values.options["app"] == ["Notes"])
        #expect(values.flags.contains("pressReturn"))
        #expect(values.flags.contains("escape"))
        #expect(values.flags.contains("delete"))
        #expect(values.flags.contains("clear"))
        #expect(values.options["focusTimeoutSeconds"] == ["3.5"])
        #expect(values.flags.contains("spaceSwitch"))
    }

    @Test
    @MainActor
    func `Commander program resolves press command options`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "press",
            "cmd",
            "c",
            "--count", "3",
            "--delay", "25",
            "--hold", "75",
            "--snapshot", "sess-1",
            "--no-auto-focus"
        ])
        let values = invocation.parsedValues
        #expect(values.positional == ["cmd", "c"])
        #expect(values.options["count"] == ["3"])
        #expect(values.options["delay"] == ["25"])
        #expect(values.options["hold"] == ["75"])
        #expect(values.options["snapshot"] == ["sess-1"])
        #expect(values.flags.contains("noAutoFocus"))
    }

    @Test
    @MainActor
    func `Commander program resolves capture video input positional`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "capture",
            "video",
            "/tmp/demo.mov",
            "--sample-fps", "3"
        ])
        let values = invocation.parsedValues
        #expect(values.positional == ["/tmp/demo.mov"])
        #expect(values.options["sampleFps"] == ["3"])
    }

    @Test
    @MainActor
    func `Commander program resolves list default to apps`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "list",
            "--json"
        ])
        #expect(invocation.path == ["list", "apps"])
        #expect(invocation.parsedValues.flags.contains("jsonOutput"))
    }

    @Test
    @MainActor
    func `Commander program resolves list menubar`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "list",
            "menubar"
        ])
        #expect(invocation.path == ["list", "menubar"])
    }

    @Test
    @MainActor
    func `Commander program resolves list screens`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "list",
            "screens"
        ])
        #expect(invocation.path == ["list", "screens"])
    }

    @Test
    @MainActor
    func `Commander program resolves scroll command options`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "scroll",
            "--direction", "down",
            "--amount", "7",
            "--on", "B4",
            "--snapshot", "sess-5",
            "--delay", "5",
            "--smooth",
            "--app", "Mail",
            "--bring-to-current-space"
        ])
        let values = invocation.parsedValues
        #expect(values.options["direction"] == ["down"])
        #expect(values.options["amount"] == ["7"])
        #expect(values.options["on"] == ["B4"])
        #expect(values.options["snapshot"] == ["sess-5"])
        #expect(values.options["delay"] == ["5"])
        #expect(values.flags.contains("smooth"))
        #expect(values.options["app"] == ["Mail"])
        #expect(values.flags.contains("bringToCurrentSpace"))
    }

    @Test
    @MainActor
    func `Commander program resolves hotkey command options`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "hotkey",
            "--keys", "cmd,c",
            "--hold-duration", "120",
            "--snapshot", "sess-11",
            "--no-auto-focus"
        ])
        let values = invocation.parsedValues
        #expect(values.options["keys"] == ["cmd,c"])
        #expect(values.options["holdDuration"] == ["120"])
        #expect(values.options["snapshot"] == ["sess-11"])
        #expect(values.flags.contains("noAutoFocus"))
    }

    @Test
    @MainActor
    func `Commander program resolves move command options`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "move",
            "120,240",
            "--to", "Submit",
            "--id", "B2",
            "--duration", "750",
            "--steps", "30",
            "--snapshot", "sess-20",
            "--center",
            "--smooth"
        ])
        let values = invocation.parsedValues
        #expect(values.positional == ["120,240"])
        #expect(values.options["to"] == ["Submit"])
        #expect(values.options["id"] == ["B2"])
        #expect(values.options["duration"] == ["750"])
        #expect(values.options["steps"] == ["30"])
        #expect(values.options["snapshot"] == ["sess-20"])
        #expect(values.flags.contains("center"))
        #expect(values.flags.contains("smooth"))
    }

    @Test
    @MainActor
    func `Commander program resolves drag command options`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "drag",
            "--from", "A1",
            "--to-coords", "300,400",
            "--snapshot", "sess-9",
            "--duration", "900",
            "--steps", "15",
            "--modifiers", "cmd,shift",
            "--bring-to-current-space"
        ])
        let values = invocation.parsedValues
        #expect(values.options["from"] == ["A1"])
        #expect(values.options["toCoords"] == ["300,400"])
        #expect(values.options["snapshot"] == ["sess-9"])
        #expect(values.options["duration"] == ["900"])
        #expect(values.options["steps"] == ["15"])
        #expect(values.options["modifiers"] == ["cmd,shift"])
        #expect(values.flags.contains("bringToCurrentSpace"))
    }

    @Test
    @MainActor
    func `Commander program resolves swipe command options`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "swipe",
            "--from-coords", "10,20",
            "--to", "B1",
            "--snapshot", "sess-8",
            "--duration", "600",
            "--steps", "12",
            "--right-button"
        ])
        let values = invocation.parsedValues
        #expect(values.options["fromCoords"] == ["10,20"])
        #expect(values.options["to"] == ["B1"])
        #expect(values.options["snapshot"] == ["sess-8"])
        #expect(values.options["duration"] == ["600"])
        #expect(values.options["steps"] == ["12"])
        #expect(values.flags.contains("rightButton"))
    }
}
