import Commander
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooCLI

@MainActor
struct InteractionTargetSelectorValidationTests {
    struct Selectors: Sendable {
        let app: String?
        let pid: Int32?
        let windowTitle: String?
        let windowIndex: Int?
        let windowID: Int?
    }

    @Test(arguments: InteractionTargetSelectorFixtures.validCases)
    func `valid shared interaction selector combinations pass`(_ selectors: InteractionTargetSelectorCase) throws {
        let target = Self.makeTarget(selectors)
        try target.validate()
    }

    @Test(arguments: InteractionTargetSelectorFixtures.applicationAndProcessIdentifierCases)
    func `app and pid fail closed`(_ selectors: InteractionTargetSelectorCase) {
        let target = Self.makeTarget(selectors)
        #expect(throws: ValidationError.self) {
            try target.validate()
        }
    }

    @Test(arguments: InteractionTargetSelectorFixtures.multipleWindowSelectorCases)
    func `multiple window selectors fail closed`(_ selectors: InteractionTargetSelectorCase) {
        let target = Self.makeTarget(selectors)
        #expect(throws: ValidationError.self) {
            try target.validate()
        }
    }

    @Test(arguments: InteractionTargetSelectorFixtures.windowSelectorRequiresApplicationCases)
    func `relative window selectors require an owner`(_ selectors: InteractionTargetSelectorCase) {
        let target = Self.makeTarget(selectors)
        #expect(throws: ValidationError.self) {
            try target.validate()
        }
    }

    @Test
    func `every phase 3 interaction surface rejects app and pid while binding`() {
        let targetOptions = ["app": ["TextEdit"], "pid": ["42"]]

        #expect(throws: (any Error).self) {
            _ = try CommanderCLIBinder.instantiateCommand(
                ofType: ActionCommand.self,
                parsedValues: ParsedValues(
                    positional: ["AXPress"],
                    options: targetOptions.merging(["on": ["B1"]]) { current, _ in current },
                    flags: []
                )
            )
        }
        #expect(throws: (any Error).self) {
            _ = try CommanderCLIBinder.instantiateCommand(
                ofType: SetValueCommand.self,
                parsedValues: ParsedValues(
                    positional: ["hello"],
                    options: targetOptions.merging(["on": ["T1"]]) { current, _ in current },
                    flags: []
                )
            )
        }
        #expect(throws: (any Error).self) {
            _ = try CommanderCLIBinder.instantiateCommand(
                ofType: PressCommand.self,
                parsedValues: ParsedValues(positional: ["cmd+c"], options: targetOptions, flags: [])
            )
        }
        #expect(throws: (any Error).self) {
            _ = try CommanderCLIBinder.instantiateCommand(
                ofType: ClickCommand.self,
                parsedValues: ParsedValues(positional: ["Save"], options: targetOptions, flags: [])
            )
        }
        #expect(throws: (any Error).self) {
            _ = try CommanderCLIBinder.instantiateCommand(
                ofType: DragCommand.self,
                parsedValues: ParsedValues(
                    positional: [],
                    options: targetOptions.merging(["from": ["0,0"], "to": ["10,10"]]) { current, _ in current },
                    flags: []
                )
            )
        }
    }

    @Test
    func `see rejects the same ambiguous selector matrix before observation`() throws {
        let invalidArguments = [
            ["--app", "TextEdit", "--pid", "42"],
            ["--app", "TextEdit", "--window-id", "7", "--window-title", "Document"],
            ["--app", "TextEdit", "--window-id", "7", "--window-index", "2"],
            ["--app", "TextEdit", "--window-title", "Document", "--window-index", "2"],
            ["--window-title", "Document"],
            ["--window-index", "2"],
        ]

        for arguments in invalidArguments {
            let command = try SeeCommand.parse(arguments)
            #expect(throws: ValidationError.self) {
                try command.validateMergedOptions()
            }
            #expect(throws: ValidationError.self) {
                try command.observationTargetForCaptureWithDetectionIfPossible()
            }
        }
    }

    @Test
    func `target resolution APIs cannot bypass selector validation`() {
        let target = Self.makeTarget(Selectors(
            app: "TextEdit",
            pid: 42,
            windowTitle: nil,
            windowIndex: nil,
            windowID: nil
        ))

        #expect(throws: ValidationError.self) {
            try target.resolveApplicationIdentifierOptional()
        }
        #expect(throws: ValidationError.self) {
            try target.toWindowTarget()
        }
        #expect(throws: ValidationError.self) {
            try target.observationTargetRequest()
        }
    }

    private static func makeTarget(_ selectors: Selectors) -> InteractionTargetOptions {
        var target = InteractionTargetOptions()
        target.app = selectors.app
        target.pid = selectors.pid
        target.windowTitle = selectors.windowTitle
        target.windowIndex = selectors.windowIndex
        target.windowId = selectors.windowID
        return target
    }

    private static func makeTarget(_ selectors: InteractionTargetSelectorCase) -> InteractionTargetOptions {
        self.makeTarget(Selectors(
            app: selectors.hasApplication ? "TextEdit" : nil,
            pid: selectors.hasProcessIdentifier ? 42 : nil,
            windowTitle: selectors.hasWindowTitle ? "Document" : nil,
            windowIndex: selectors.hasWindowIndex ? 2 : nil,
            windowID: selectors.hasWindowID ? 7 : nil
        ))
    }
}
