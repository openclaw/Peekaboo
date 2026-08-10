import Testing
@testable import PeekabooCLI

@MainActor
struct CommanderRuntimeActionClassificationTests {
    @Test
    func `every registered leaf follows ActionOutputFormattable classification`() {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        for (path, descriptor) in Self.leafDescriptors(descriptors) {
            let expected = (descriptor.type.init() as? any ActionOutputFormattable)?.defaultEffect != nil
            let actual = CommanderRuntimeRouter.isActionInvocation(argv: ["peekaboo"] + path)

            #expect(actual == expected, "Incorrect result-envelope classification for \(path.joined(separator: " "))")
        }
    }

    @Test
    func `unknown and incomplete command paths are not actions`() {
        #expect(!CommanderRuntimeRouter.isActionInvocation(argv: ["peekaboo", "unknown", "--json"]))
        #expect(!CommanderRuntimeRouter.isActionInvocation(argv: ["peekaboo", "window", "--json"]))
        #expect(!CommanderRuntimeRouter.isActionInvocation(argv: ["peekaboo", "window", "unknown", "--json"]))
    }

    @Test
    func `capture selector shapes stay read-only while window and space mutations are actions`() {
        let captureShapes = [
            ["peekaboo", "capture", "live", "--app", "Example", "--pid", "123", "--json"],
            ["peekaboo", "capture", "live", "--window-title", "Main", "--window-index", "0", "--json"],
            [
                "peekaboo", "capture", "live", "--mode", "screen", "--screen-index", "0", "--app", "Example",
                "--json",
            ],
        ]
        for argv in captureShapes {
            #expect(!CommanderRuntimeRouter.isActionInvocation(argv: argv))
        }

        #expect(CommanderRuntimeRouter.isActionInvocation(argv: [
            "peekaboo", "window", "close", "--window-title", "Main", "--window-index", "0", "--json",
        ]))
        #expect(CommanderRuntimeRouter.isActionInvocation(argv: [
            "peekaboo", "space", "move-window", "--app", "Example", "--pid", "123", "--to", "1", "--json",
        ]))
    }

    private static func leafDescriptors(
        _ descriptors: [CommanderCommandDescriptor],
        prefix: [String] = []
    ) -> [(path: [String], descriptor: CommanderCommandDescriptor)] {
        descriptors.flatMap { descriptor in
            let path = prefix + [descriptor.metadata.name]
            guard !descriptor.subcommands.isEmpty else { return [(path, descriptor)] }
            return self.leafDescriptors(descriptor.subcommands, prefix: path)
        }
    }
}
