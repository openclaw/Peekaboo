import Commander
import Testing
@testable import PeekabooCLI

struct CommanderBinderSpaceDialogTests {
    @Test
    @MainActor
    func `Commander program resolves space list options`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "space",
            "list",
            "--detailed",
        ])
        let values = invocation.parsedValues
        #expect(values.flags.contains("detailed"))
    }

    @Test
    @MainActor
    func `Commander program resolves space switch options`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "space",
            "switch",
            "--to", "3",
            "--foreground",
        ])
        let values = invocation.parsedValues
        #expect(values.options["to"] == ["3"])
        #expect(values.flags.contains("foreground"))
    }

    @Test
    @MainActor
    func `Commander program resolves space move-window options`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "space",
            "move-window",
            "--app", "Safari",
            "--window-id", "42",
            "--window-title", "Inbox",
            "--window-index", "2",
            "--to", "4",
            "--follow",
            "--foreground",
        ])
        let values = invocation.parsedValues
        #expect(values.options["app"] == ["Safari"])
        #expect(values.options["windowId"] == ["42"])
        #expect(values.options["windowTitle"] == ["Inbox"])
        #expect(values.options["windowIndex"] == ["2"])
        #expect(values.options["to"] == ["4"])
        #expect(values.flags.contains("follow"))
        #expect(values.flags.contains("foreground"))
    }

    @Test
    @MainActor
    func `space move-window validation rejects conflicting title and index selectors`() throws {
        var command = try MoveWindowSubcommand.parse([
            "--app", "Fixture",
            "--window-title", "Draft",
            "--window-index", "0",
            "--to-current",
        ])

        #expect(throws: Commander.ValidationError.self) {
            try command.validate()
        }
    }

    @Test
    @MainActor
    func `space move-window validation accepts exact window ID without owner`() throws {
        var command = try MoveWindowSubcommand.parse([
            "--window-id", "42",
            "--to-current",
        ])

        try command.validate()
        #expect(command.windowId == 42)
        #expect(command.app == nil)
    }

    @Test
    @MainActor
    func `Commander program resolves dialog click options`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "dialog",
            "click",
            "--button", "OK",
            "--window-title", "Save",
        ])
        let values = invocation.parsedValues
        #expect(values.options["button"] == ["OK"])
        #expect(values.options["windowTitle"] == ["Save"])
    }

    @Test
    @MainActor
    func `Commander program resolves dialog input options`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation = try program.resolve(argv: [
            "peekaboo",
            "dialog",
            "input",
            "--text", "Report generated",
            "--window-title", "Export",
        ])
        let values = invocation.parsedValues
        #expect(values.options["text"] == ["Report generated"])
        #expect(values.options["windowTitle"] == ["Export"])
    }
}
