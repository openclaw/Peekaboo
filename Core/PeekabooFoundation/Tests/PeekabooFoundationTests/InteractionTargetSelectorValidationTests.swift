import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooFoundation

struct InteractionTargetSelectorValidationTests {
    @Test(arguments: InteractionTargetSelectorFixtures.validCases)
    func `valid selector combinations pass`(_ selectors: InteractionTargetSelectorCase) throws {
        #expect(selectors.expectedFailure == nil)
        try Self.validate(selectors)
    }

    @Test(arguments: InteractionTargetSelectorFixtures.applicationAndProcessIdentifierCases)
    func `app and pid combinations fail closed`(_ selectors: InteractionTargetSelectorCase) {
        #expect(selectors.expectedFailure == .applicationAndProcessIdentifier)
        #expect(throws: InteractionTargetSelectorValidationError.applicationAndProcessIdentifier) {
            try Self.validate(selectors)
        }
    }

    @Test(arguments: InteractionTargetSelectorFixtures.multipleWindowSelectorCases)
    func `multiple window selectors fail closed`(_ selectors: InteractionTargetSelectorCase) {
        #expect(selectors.expectedFailure == .multipleWindowSelectors)
        #expect(throws: InteractionTargetSelectorValidationError.multipleWindowSelectors) {
            try Self.validate(selectors)
        }
    }

    @Test(arguments: InteractionTargetSelectorFixtures.windowSelectorRequiresApplicationCases)
    func `relative window selectors require an application owner`(_ selectors: InteractionTargetSelectorCase) {
        #expect(selectors.expectedFailure == .windowSelectorRequiresApplication)
        #expect(throws: InteractionTargetSelectorValidationError.windowSelectorRequiresApplication) {
            try Self.validate(selectors)
        }
    }

    private static func validate(_ selectors: InteractionTargetSelectorCase) throws {
        try InteractionTargetSelectorValidator.validate(
            hasApplication: selectors.hasApplication,
            hasProcessIdentifier: selectors.hasProcessIdentifier,
            hasWindowID: selectors.hasWindowID,
            hasWindowTitle: selectors.hasWindowTitle,
            hasWindowIndex: selectors.hasWindowIndex)
    }

    @Test
    func `canonical syntax retains raw channels while exposing normalized values`() throws {
        let selector = InteractionTargetSelector(
            applicationIdentifier: "  Preview  ",
            windowTitle: "  Main  ")

        #expect(selector.applicationIdentifier == "  Preview  ")
        #expect(selector.windowTitle == "  Main  ")
        #expect(selector.normalizedApplicationIdentifier == "Preview")
        #expect(selector.normalizedWindowTitle == "Main")
        #expect(try selector.normalizedApplicationTarget(policy: .interaction) == "Preview")
        #expect(try selector.normalizedWindowSelector(policy: .interaction) == .title("Main"))
    }

    @Test
    func `canonical syntax distinguishes absent and supplied empty strings`() {
        let absent = InteractionTargetSelector()
        let suppliedEmpty = InteractionTargetSelector(applicationIdentifier: "  ")

        #expect(absent.applicationIdentifier == nil)
        #expect(!absent.hasAnyInput)
        #expect(suppliedEmpty.applicationIdentifier != nil)
        #expect(suppliedEmpty.normalizedApplicationIdentifier == nil)
        #expect(suppliedEmpty.hasAnyInput)
        #expect(throws: InteractionTargetSelector.ValidationError.emptyApplication) {
            try suppliedEmpty.validate(policy: .dialogOwnerRequired)
        }
        #expect(throws: Never.self) {
            try suppliedEmpty.validate(policy: .interaction)
        }
    }

    @Test
    func `canonical mutation-safe policy validates numeric ranges`() {
        #expect(throws: InteractionTargetSelector.ValidationError.invalidProcessIdentifier) {
            try InteractionTargetSelector(processIdentifier: 0).validate(policy: .mutationSafe)
        }
        #expect(throws: InteractionTargetSelector.ValidationError.invalidProcessIdentifier) {
            try InteractionTargetSelector(processIdentifier: Int(Int32.max) + 1).validate(policy: .mutationSafe)
        }
        #expect(throws: InteractionTargetSelector.ValidationError.invalidWindowID) {
            try InteractionTargetSelector(windowID: Int(UInt32.max) + 1).validate(policy: .mutationSafe)
        }
        #expect(throws: InteractionTargetSelector.ValidationError.invalidWindowIndex) {
            try InteractionTargetSelector(applicationIdentifier: "Preview", windowIndex: -1)
                .validate(policy: .mutationSafe)
        }
    }

    @Test
    func `window policies preserve their distinct shipped grammars`() throws {
        let globalTitle = InteractionTargetSelector(windowTitle: "Document")
        #expect(throws: InteractionTargetSelector.ValidationError.windowSelectorRequiresApplication) {
            try globalTitle.validate(policy: .interaction)
        }
        #expect(try globalTitle.normalizedWindowSelector(policy: .windowGlobalTitleAllowed) == .title("Document"))

        let redundantPID = InteractionTargetSelector(
            applicationIdentifier: "PID:42",
            processIdentifier: 42)
        #expect(try redundantPID.normalizedApplicationTarget(policy: .windowCLI()) == "PID:42")
        #expect(throws: InteractionTargetSelector.ValidationError.applicationAndProcessIdentifier) {
            try redundantPID.validate(policy: .interaction)
        }

        let conflictingPID = InteractionTargetSelector(
            applicationIdentifier: "PID:41",
            processIdentifier: 42)
        #expect(throws: InteractionTargetSelector.ValidationError.conflictingProcessIdentifiers(
            application: 41,
            explicit: 42))
        {
            try conflictingPID.validate(policy: .windowCLI())
        }
    }

    @Test
    func `strict policy rejects ambiguous and empty selector syntax`() {
        #expect(throws: InteractionTargetSelector.ValidationError.windowSelectorRequiresApplication) {
            try InteractionTargetSelector(windowTitle: "Main").validate(policy: .mutationSafe)
        }
        #expect(throws: InteractionTargetSelector.ValidationError.multipleWindowSelectors) {
            try InteractionTargetSelector(
                applicationIdentifier: "Preview",
                windowID: 7,
                windowTitle: "Main")
                .validate(policy: .mutationSafe)
        }
        #expect(throws: InteractionTargetSelector.ValidationError.emptyWindowTitle) {
            try InteractionTargetSelector(applicationIdentifier: "Preview", windowTitle: " ")
                .validate(policy: .mutationSafe)
        }
    }
}
