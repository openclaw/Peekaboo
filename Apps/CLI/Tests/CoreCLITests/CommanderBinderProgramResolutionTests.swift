import Commander
import Testing
@testable import PeekabooCLI

struct CommanderBinderProgramResolutionTests {
    @Test
    func `Commander configuration failures retain actionable CLI messages`() {
        #expect(
            commanderErrorMessage(.duplicateCommand("see")) ==
                "Duplicate root command 'see'"
        )
        #expect(
            commanderErrorMessage(.duplicateSubcommand(command: "window manage", name: "move")) ==
                "Duplicate subcommand 'move' for command 'window manage'"
        )
        #expect(
            commanderErrorMessage(.invalidDefaultSubcommand(command: "window", name: "inspect")) ==
                "Default subcommand 'inspect' is not registered for command 'window'"
        )
        #expect(
            commanderErrorMessage(.invalidCommandSignature(
                command: "see",
                error: .conflictingName(spelling: "--json", optionLabel: "json", flagLabel: "jsonOutput")
            )) ==
                "Invalid signature for command 'see': " +
                "Conflicting spelling --json for option 'json' and flag 'jsonOutput'"
        )
    }

    @Test
    @MainActor
    func `Commander program resolves screenshot-only see options`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "see",
            "--no-elements",
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
        #expect(values.flags.contains("noElements"))
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
    func `Commander program preserves see traversal and path aliases`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        for alias in ["--path", "--save", "--output", "-o"] {
            let invocation = try program.resolve(argv: [
                "peekaboo",
                "see",
                alias, "/tmp/see.png",
                "--depth", "8",
                "--max-elements", "500",
                "--max-children", "100",
            ])
            let values = invocation.parsedValues
            #expect(values.options["path"] == ["/tmp/see.png"])
            #expect(values.options["depth"] == ["8"])
            #expect(values.options["maxElements"] == ["500"])
            #expect(values.options["maxChildren"] == ["100"])
        }
        let modeHelp = SeeCommand.commanderSignature().options.first { $0.label == "mode" }?.help
        #expect(modeHelp?.contains("multi") == true)
    }

    @Test
    @MainActor
    func `See selector help states ownership requirements`() {
        let options = Dictionary(uniqueKeysWithValues: SeeCommand.commanderSignature().options.map {
            ($0.label, $0.help ?? "")
        })

        #expect(options["app"]?.contains("mutually exclusive with --pid") == true)
        #expect(options["pid"]?.contains("mutually exclusive with --app") == true)
        #expect(options["windowTitle"]?.contains("requires --app or --pid") == true)
        #expect(options["windowIndex"]?.contains("requires --app or --pid") == true)
        #expect(options["windowId"]?.contains("may be used without --app/--pid") == true)
    }

    @Test
    @MainActor
    func `Press usage honestly marks repeated chords and explicit snapshots`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let descriptor = try #require(descriptors.first { $0.metadata.name == "press" })
        let usage = CommanderRuntimeRouter.buildUsageLine(
            path: ["press"],
            signature: descriptor.metadata.signature
        )
        let invocation = try Program(descriptors: descriptors.map(\.metadata)).resolve(argv: [
            "peekaboo", "press", "cmd+c", "Return", "--foreground",
        ])
        let snapshotHelp = PressCommand.commanderSignature().options.first { $0.label == "snapshot" }?.help
        let typeSnapshotHelp = TypeCommand.commanderSignature().options.first { $0.label == "snapshot" }?.help

        #expect(usage.contains("[<chord> ...]"))
        #expect(descriptor.metadata.signature.arguments.first?.parsing == .remaining)
        #expect(invocation.parsedValues.positional == ["cmd+c", "Return"])
        #expect(snapshotHelp?.contains("never infers latest") == true)
        #expect(typeSnapshotHelp?.contains("no snapshot is inferred") == true)
    }

    @Test
    @MainActor
    func `Commander program rejects excess fixed positional arguments`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))

        #expect(throws: CommanderProgramError.parsingError(.unexpectedArgument("extra"))) {
            _ = try program.resolve(argv: ["peekaboo", "type", "Hello", "extra", "--foreground"])
        }
    }

    @Test
    @MainActor
    func `Commander program preserves window documented options`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let listInvocation = try program.resolve(argv: [
            "peekaboo", "window", "list", "--app", "Finder", "--group-by-space",
        ])
        #expect(listInvocation.parsedValues.flags.contains("groupBySpace"))

        let resizeInvocation = try program.resolve(argv: [
            "peekaboo", "window", "resize", "--app", "Finder", "-w", "800", "--height", "600",
        ])
        #expect(resizeInvocation.parsedValues.options["width"] == ["800"])

        let boundsInvocation = try program.resolve(argv: [
            "peekaboo", "window", "set-bounds", "--app", "Finder",
            "--x", "0", "--y", "0", "-w", "800", "--height", "600",
        ])
        #expect(boundsInvocation.parsedValues.options["width"] == ["800"])
    }

    @Test
    @MainActor
    func `App launch help treats app as optional with bundle identifier`() throws {
        let argument = AppCommand.LaunchSubcommand.commanderSignature().arguments.first
        #expect(argument?.label == "app")
        #expect(argument?.isOptional == true)

        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo", "app", "launch", "--bundle-id", "com.apple.TextEdit",
        ])
        #expect(invocation.parsedValues.positional.isEmpty)
        #expect(invocation.parsedValues.options["bundleId"] == ["com.apple.TextEdit"])
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
    func `Commander program resolves AX-only see command`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "see",
            "--tree",
            "--no-screenshot",
            "--app", "TextEdit",
            "--max-elements", "200",
        ])
        let values = invocation.parsedValues
        #expect(invocation.path == ["see"])
        #expect(values.options["app"] == ["TextEdit"])
        #expect(values.options["maxElements"] == ["200"])
        #expect(values.flags.contains("tree"))
        #expect(values.flags.contains("noScreenshot"))
    }

    @Test
    @MainActor
    func `Commander program resolves AX-only see app target`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "see",
            "--tree",
            "--no-screenshot",
            "--app", "TextEdit",
        ])
        #expect(invocation.parsedValues.options["app"] == ["TextEdit"])
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
        #expect(values.positional == ["echo", "hello", "--flag"])
        #expect(values.options["command"] == nil)
    }

    @Test
    @MainActor
    func `Commander program keeps natural-language agent tasks positional`() throws {
        let invocation = try CommanderRuntimeRouter.resolve(argv: [
            "peekaboo",
            "agent",
            "list files",
            "--dry-run",
        ])

        #expect(invocation.metadata.name == "run")
        #expect(invocation.parsedValues.positional == ["list files"])
        #expect(invocation.parsedValues.flags.contains("dryRun"))
    }

    @Test
    @MainActor
    func `Runtime router treats full argv and argument tail equivalently`() throws {
        let full = try CommanderRuntimeRouter.resolve(argv: [
            "peekaboo",
            "agent",
            "list files",
            "--dry-run",
        ])
        let tail = try CommanderRuntimeRouter.resolve(argv: [
            "agent",
            "list files",
            "--dry-run",
        ])

        #expect(full.metadata.name == "run")
        #expect(full.metadata.name == tail.metadata.name)
        #expect(ObjectIdentifier(full.type) == ObjectIdentifier(tail.type))
        #expect(full.parsedValues == tail.parsedValues)
    }

    @Test
    @MainActor
    func `V4 command restructures resolve nested paths`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))

        #expect(try program.resolve(argv: ["peekaboo", "clipboard", "set", "--text", "hi"]).path == [
            "clipboard", "set",
        ])
        #expect(try program.resolve(argv: ["peekaboo", "menubar", "click", "Wi-Fi"]).path == [
            "menubar", "click",
        ])
        #expect(try program.resolve(argv: ["peekaboo", "config", "provider", "models", "local"]).path == [
            "config", "provider", "models",
        ])
        #expect(try program.resolve(argv: ["peekaboo", "agent", "sessions", "--json"]).path == [
            "agent", "sessions",
        ])
        #expect(try program.resolve(argv: ["peekaboo", "permissions", "request", "accessibility"]).path == [
            "permissions", "request",
        ])
    }

    @Test
    @MainActor
    func `V4 removed spellings are rejected`() {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let removed = [
            ["peekaboo", "clipboard", "-a", "get"],
            ["peekaboo", "config", "add-provider"],
            ["peekaboo", "agent", "--list-sessions"],
            ["peekaboo", "permissions", "request-screen-recording"],
        ]

        for argv in removed {
            #expect(throws: CommanderProgramError.self, "Expected rejection for \(argv)") {
                _ = try program.resolve(argv: argv)
            }
        }
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
    func `Commander program resolves click background focus flag`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "click",
            "--at", "10,10",
            "--app", "Safari",
            "--focus-background"
        ])
        let values = invocation.parsedValues
        #expect(values.options["at"] == ["10,10"])
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
            "--clear",
            "--app", "Notes",
            "--focus-timeout", "3.5s",
            "--space-switch"
        ])
        let values = invocation.parsedValues
        #expect(values.positional == ["Hello"])
        #expect(values.options["snapshot"] == ["xyz"])
        #expect(values.options["delay"] == ["10"])
        #expect(values.options["app"] == ["Notes"])
        #expect(values.flags.contains("clear"))
        #expect(values.options["focusTimeout"] == ["3.5s"])
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
            "cmd+c",
            "--count", "3",
            "--delay", "25",
            "--hold", "75",
            "--snapshot", "sess-1",
            "--no-auto-focus"
        ])
        let values = invocation.parsedValues
        #expect(values.positional == ["cmd+c"])
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
    func `Commander program resolves screen list`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "screen",
            "list",
            "--json"
        ])
        #expect(invocation.path == ["screen", "list"])
        #expect(invocation.parsedValues.flags.contains("jsonOutput"))
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
    func `Commander program resolves move command options`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "move",
            "--at", "120,240",
            "--on", "B2",
            "--duration", "750",
            "--steps", "30",
            "--snapshot", "sess-20",
            "--smooth"
        ])
        let values = invocation.parsedValues
        #expect(values.positional.isEmpty)
        #expect(values.options["at"] == ["120,240"])
        #expect(values.options["on"] == ["B2"])
        #expect(values.options["duration"] == ["750"])
        #expect(values.options["steps"] == ["30"])
        #expect(values.options["snapshot"] == ["sess-20"])
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
            "--to", "300,400",
            "--snapshot", "sess-9",
            "--duration", "900",
            "--steps", "15",
            "--modifiers", "cmd,shift",
            "--button", "right",
            "--bring-to-current-space"
        ])
        let values = invocation.parsedValues
        #expect(values.options["from"] == ["A1"])
        #expect(values.options["to"] == ["300,400"])
        #expect(values.options["snapshot"] == ["sess-9"])
        #expect(values.options["duration"] == ["900"])
        #expect(values.options["steps"] == ["15"])
        #expect(values.options["modifiers"] == ["cmd,shift"])
        #expect(values.options["button"] == ["right"])
        #expect(values.flags.contains("bringToCurrentSpace"))
    }
}
