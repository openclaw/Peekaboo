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
}
