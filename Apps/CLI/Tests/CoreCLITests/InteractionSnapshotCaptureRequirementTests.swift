import Commander
import Testing
@testable import PeekabooCLI

struct InteractionSnapshotCaptureRequirementTests {
    @Test
    func `Concrete interaction snapshots cannot trigger silent capture`() throws {
        let concreteCases: [(any ParsableCommand.Type, ParsedValues)] = [
            (ClickCommand.self, ParsedValues(
                positional: [],
                options: ["on": ["B1"], "snapshot": ["receipt-1"]],
                flags: ["foreground"]
            )),
            (ScrollCommand.self, ParsedValues(
                positional: [],
                options: ["on": ["S1"], "snapshot": ["receipt-1"]],
                flags: []
            )),
            (MoveCommand.self, ParsedValues(
                positional: [],
                options: ["on": ["B1"], "snapshot": ["receipt-1"]],
                flags: ["foreground"]
            )),
            (DragCommand.self, ParsedValues(
                positional: [],
                options: ["from": ["B1"], "to": ["B2"], "snapshot": ["receipt-1"]],
                flags: ["foreground"]
            )),
        ]

        for (commandType, values) in concreteCases {
            let options = try CommanderCLIBinder.makeRuntimeOptions(from: values, commandType: commandType)
            #expect(!options.requiresSilentCapture, "Concrete snapshot unexpectedly captured for \(commandType)")
        }

        for snapshot in [nil, "", " ", "latest", "most-recent", "most_recent"] {
            let snapshotOptions = snapshot.map { ["snapshot": [$0]] } ?? [:]
            let options = try CommanderCLIBinder.makeRuntimeOptions(
                from: ParsedValues(
                    positional: [],
                    options: ["on": ["S1"]].merging(snapshotOptions) { _, latest in latest },
                    flags: []
                ),
                commandType: ScrollCommand.self
            )
            #expect(options.requiresSilentCapture, "Refreshable snapshot was treated as concrete: \(snapshot ?? "nil")")
        }
    }
}
