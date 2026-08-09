import Commander
import Testing
@testable import PeekabooCLI

struct CommanderBinderMCPWindowTests {
    @Test
    @MainActor
    func `Commander program resolves MCP serve options`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "mcp",
            "serve",
            "--transport", "http",
            "--port", "9090"
        ])
        let values = invocation.parsedValues
        #expect(values.options["transport"] == ["http"])
        #expect(values.options["port"] == ["9090"])
    }

    @Test
    @MainActor
    func `MCP serve defaults to local runtime`() throws {
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: []),
            commandType: MCPCommand.Serve.self
        )

        #expect(!options.preferRemote)
    }

    @Test
    @MainActor
    func `Commander program resolves window close options`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "window",
            "close",
            "--app", "Safari",
            "--window-title", "Inbox"
        ])
        let values = invocation.parsedValues
        #expect(values.options["app"] == ["Safari"])
        #expect(values.options["windowTitle"] == ["Inbox"])
    }

    @Test
    @MainActor
    func `Commander program resolves window move options`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "window",
            "move",
            "--app", "Notes",
            "--x", "120",
            "--y", "240"
        ])
        let values = invocation.parsedValues
        #expect(values.options["app"] == ["Notes"])
        #expect(values.options["x"] == ["120"])
        #expect(values.options["y"] == ["240"])
    }

    @Test
    @MainActor
    func `Commander program resolves window focus options`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "window",
            "focus",
            "--app", "Safari",
            "--window-title", "Inbox",
            "--snapshot", "snapshot-123",
            "--space-switch",
            "--bring-to-current-space"
        ])
        let values = invocation.parsedValues
        #expect(values.options["app"] == ["Safari"])
        #expect(values.options["windowTitle"] == ["Inbox"])
        #expect(values.options["snapshot"] == ["snapshot-123"])
        #expect(values.flags.contains("spaceSwitch"))
        #expect(values.flags.contains("bringToCurrentSpace"))
    }

    @Test
    @MainActor
    func `Commander program resolves app launch options`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "app",
            "launch",
            "\"Visual Studio Code\"",
            "--bundle-id", "com.microsoft.VSCode",
            "--wait-ready"
        ])
        let values = invocation.parsedValues
        #expect(values.positional == ["\"Visual Studio Code\""])
        #expect(values.options["bundleId"] == ["com.microsoft.VSCode"])
        #expect(values.flags.contains("waitUntilReady"))
    }

    @Test
    @MainActor
    func `Commander program resolves app quit options`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "app",
            "quit",
            "--pid", "123",
            "--expected-process-start-identity", "456789",
            "--force"
        ])
        let values = invocation.parsedValues
        #expect(values.options["pid"] == ["123"])
        #expect(values.options["expectedProcessStartIdentity"] == ["456789"])
        #expect(values.flags.contains("force"))
    }

    @Test
    @MainActor
    func `Commander program resolves menu click options`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "menu",
            "click",
            "--app", "Safari",
            "--path", "File > New",
            "--no-auto-focus"
        ])
        let values = invocation.parsedValues
        #expect(values.options["app"] == ["Safari"])
        #expect(values.options["path"] == ["File > New"])
        #expect(values.flags.contains("noAutoFocus"))
    }

    @Test
    @MainActor
    func `Commander program resolves permissions default subcommand`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "permissions",
            "--json"
        ])
        #expect(invocation.path == ["permissions", "status"])
        #expect(invocation.parsedValues.flags.contains("jsonOutput"))
    }

    @Test
    @MainActor
    func `Commander program resolves tools command options`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "tools",
            "--no-sort",
            "--verbose"
        ])
        let values = invocation.parsedValues
        #expect(values.flags.contains("noSort"))
        #expect(values.flags.contains("verbose"))
    }
}
