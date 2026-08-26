import Commander
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooCLI

struct InteractionSnapshotCaptureRequirementTests {
    @Test
    func `Concrete interaction snapshots cannot trigger silent capture`() throws {
        let concreteCases: [(any ParsableCommand.Type, ParsedValues)] = [
            (ClickCommand.self, ParsedValues(
                positional: [],
                options: ["on": ["B1"], "snapshot": [SnapshotReferenceFixtures.first.rawValue]],
                flags: ["foreground"]
            )),
            (ScrollCommand.self, ParsedValues(
                positional: [],
                options: ["on": ["S1"], "snapshot": [SnapshotReferenceFixtures.first.rawValue]],
                flags: []
            )),
            (MoveCommand.self, ParsedValues(
                positional: [],
                options: ["on": ["B1"], "snapshot": [SnapshotReferenceFixtures.first.rawValue]],
                flags: ["foreground"]
            )),
            (DragCommand.self, ParsedValues(
                positional: [],
                options: ["from": ["B1"], "to": ["B2"], "snapshot": [SnapshotReferenceFixtures.first.rawValue]],
                flags: ["foreground"]
            )),
            (ActionCommand.self, ParsedValues(
                positional: ["AXPress"],
                options: ["on": ["B1"], "snapshot": [SnapshotReferenceFixtures.first.rawValue], "app": ["TextEdit"]],
                flags: []
            )),
            (SetValueCommand.self, ParsedValues(
                positional: ["value"],
                options: ["on": ["B1"], "snapshot": [SnapshotReferenceFixtures.first.rawValue], "pid": ["123"]],
                flags: []
            )),
            (TypeCommand.self, ParsedValues(
                positional: ["text"],
                options: ["snapshot": [SnapshotReferenceFixtures.first.rawValue]],
                flags: []
            )),
            (PressCommand.self, ParsedValues(
                positional: ["return"],
                options: ["snapshot": [SnapshotReferenceFixtures.first.rawValue]],
                flags: []
            )),
            (PasteCommand.self, ParsedValues(
                positional: ["text"],
                options: ["snapshot": [SnapshotReferenceFixtures.first.rawValue]],
                flags: []
            )),
        ]

        for (commandType, values) in concreteCases {
            let options: CommandRuntimeOptions
            do {
                options = try CommanderCLIBinder.makeRuntimeOptions(from: values, commandType: commandType)
            } catch {
                Issue.record("\(commandType) rejected canonical snapshot: \(error)")
                continue
            }
            #expect(!options.requiresSilentCapture, "Concrete snapshot unexpectedly captured for \(commandType)")
            #expect(options.explicitSnapshotID == SnapshotReferenceFixtures.first.rawValue)
        }

        let refreshableCases: [(any ParsableCommand.Type, ParsedValues)] = [
            (ClickCommand.self, ParsedValues(
                positional: [],
                options: ["on": ["B1"]],
                flags: ["foreground"]
            )),
            (ScrollCommand.self, ParsedValues(
                positional: [],
                options: ["on": ["S1"]],
                flags: []
            )),
            (MoveCommand.self, ParsedValues(
                positional: [],
                options: ["on": ["B1"]],
                flags: ["foreground"]
            )),
            (DragCommand.self, ParsedValues(
                positional: [],
                options: ["from": ["B1"], "to": ["B2"]],
                flags: ["foreground"]
            )),
            (ActionCommand.self, ParsedValues(
                positional: ["AXPress"],
                options: ["on": ["B1"], "app": ["TextEdit"]],
                flags: []
            )),
            (SetValueCommand.self, ParsedValues(
                positional: ["value"],
                options: ["on": ["B1"], "pid": ["123"]],
                flags: []
            )),
        ]

        for snapshot in [nil, "latest", "most-recent", "most_recent"] {
            let snapshotOptions = snapshot.map { ["snapshot": [$0]] } ?? [:]
            for (commandType, values) in refreshableCases {
                let options = try CommanderCLIBinder.makeRuntimeOptions(
                    from: ParsedValues(
                        positional: values.positional,
                        options: values.options.merging(snapshotOptions) { _, latest in latest },
                        flags: values.flags
                    ),
                    commandType: commandType
                )
                #expect(
                    options.requiresSilentCapture,
                    "Refreshable snapshot was treated as concrete for \(commandType): \(snapshot ?? "nil")"
                )
                #expect(options.explicitSnapshotID == nil)
            }
        }
    }

    @Test
    func `Nonmutating snapshot argument does not request host affinity`() throws {
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["snapshot": [SnapshotReferenceFixtures.first.rawValue]],
                flags: []
            ),
            commandType: CleanCommand.self
        )

        #expect(!options.requiresImplicitSnapshotInvalidation)
        #expect(options.explicitSnapshotID == nil)
    }

    @Test
    func `Unknown snapshot references stay explicit instead of enabling future capture`() {
        #expect(InteractionSnapshotReference.isConcrete("future-alias"))
        #expect(InteractionSnapshotReference.isConcrete(" receipt-1 "))
        #expect(!InteractionSnapshotReference.isConcrete("latest"))
        #expect(!InteractionSnapshotReference.isConcrete(nil))
    }

    @Test
    func `Mutating commands reject malformed concrete snapshot references before runtime`() {
        for snapshotID in ["", " ", "1787675983803-1514", "PS1_00000000000000000000000000000000"] {
            #expect(throws: ValidationError.self) {
                _ = try CommanderCLIBinder.makeRuntimeOptions(
                    from: ParsedValues(
                        positional: [],
                        options: ["snapshot": [snapshotID], "on": ["B1"]],
                        flags: []
                    ),
                    commandType: ClickCommand.self
                )
            }
        }

        let canonical = SnapshotReferenceFixtures.first.rawValue
        let options = try? CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["snapshot": [canonical], "on": ["B1"]],
                flags: []
            ),
            commandType: ClickCommand.self
        )
        #expect(options?.explicitSnapshotID == canonical)
    }

    @Test
    func `Untargeted element actions do not require silent capture`() throws {
        for commandType in [ActionCommand.self, SetValueCommand.self] as [any ParsableCommand.Type] {
            for snapshot in [nil, "latest"] {
                let options = try CommanderCLIBinder.makeRuntimeOptions(
                    from: ParsedValues(
                        positional: ["value-or-action"],
                        options: ["on": ["B1"]].merging(snapshot.map { ["snapshot": [$0]] } ?? [:]) { _, latest in
                            latest
                        },
                        flags: []
                    ),
                    commandType: commandType
                )
                #expect(
                    !options.requiresSilentCapture,
                    "Untargeted element action unexpectedly required capture for \(commandType)"
                )
            }
        }
    }

    @Test
    func `Targeted element actions without an element reference do not require silent capture`() throws {
        for commandType in [ActionCommand.self, SetValueCommand.self] as [any ParsableCommand.Type] {
            for snapshot in [nil, "latest"] {
                for elementReference in [nil, "", " "] as [String?] {
                    var options = ["app": ["TextEdit"]]
                    if let snapshot {
                        options["snapshot"] = [snapshot]
                    }
                    if let elementReference {
                        options["on"] = [elementReference]
                    }
                    let runtimeOptions = try CommanderCLIBinder.makeRuntimeOptions(
                        from: ParsedValues(
                            positional: ["value-or-action"],
                            options: options,
                            flags: []
                        ),
                        commandType: commandType
                    )
                    #expect(
                        !runtimeOptions.requiresSilentCapture,
                        "Missing element reference unexpectedly required capture for \(commandType)"
                    )
                }
            }
        }
    }

    @Test
    func `Refreshable direct actions resolve capture ownership for every valid target selector`() throws {
        let selectors: [[String: [String]]] = [
            ["windowId": ["42"]],
            ["app": ["TextEdit"], "windowTitle": ["Document"]],
            ["pid": ["123"], "windowIndex": ["0"]],
        ]
        let commands: [(any ParsableCommand.Type, [String])] = [
            (ActionCommand.self, ["AXIncrement"]),
            (SetValueCommand.self, ["hello"]),
        ]

        for (commandType, positional) in commands {
            for selector in selectors {
                let values = ParsedValues(
                    positional: positional,
                    options: selector.merging(["on": ["B1"]]) { _, latest in latest },
                    flags: []
                )
                let options = try CommanderCLIBinder.makeRuntimeOptions(from: values, commandType: commandType)

                #expect(options.requiresSilentCapture, "Missing capture planning for \(commandType): \(selector)")
                #expect(RuntimeHostResolver.requiresCallerLocalScreenCaptureKitSafetyCheck(
                    options: options,
                    environment: [:]
                ))

                let concreteValues = ParsedValues(
                    positional: positional,
                    options: values.options.merging(
                        ["snapshot": [SnapshotReferenceFixtures.first.rawValue]]
                    ) { _, latest in latest },
                    flags: []
                )
                let concreteOptions = try CommanderCLIBinder.makeRuntimeOptions(
                    from: concreteValues,
                    commandType: commandType
                )
                #expect(!concreteOptions.requiresSilentCapture)
                #expect(!RuntimeHostResolver.requiresCallerLocalScreenCaptureKitSafetyCheck(
                    options: concreteOptions,
                    environment: [:]
                ))
            }
        }
    }
}
