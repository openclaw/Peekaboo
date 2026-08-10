import Testing
@testable import PeekabooFoundation

struct InteractionTargetSelectorValidationTests {
    struct Selectors: Sendable {
        let app: Bool
        let pid: Bool
        let windowID: Bool
        let windowTitle: Bool
        let windowIndex: Bool
    }

    @Test(arguments: [
        Selectors(app: false, pid: false, windowID: false, windowTitle: false, windowIndex: false),
        Selectors(app: true, pid: false, windowID: false, windowTitle: false, windowIndex: false),
        Selectors(app: false, pid: true, windowID: false, windowTitle: false, windowIndex: false),
        Selectors(app: false, pid: false, windowID: true, windowTitle: false, windowIndex: false),
        Selectors(app: true, pid: false, windowID: true, windowTitle: false, windowIndex: false),
        Selectors(app: false, pid: true, windowID: true, windowTitle: false, windowIndex: false),
        Selectors(app: true, pid: false, windowID: false, windowTitle: true, windowIndex: false),
        Selectors(app: false, pid: true, windowID: false, windowTitle: true, windowIndex: false),
        Selectors(app: true, pid: false, windowID: false, windowTitle: false, windowIndex: true),
        Selectors(app: false, pid: true, windowID: false, windowTitle: false, windowIndex: true),
    ])
    func `valid selector combinations pass`(_ selectors: Selectors) throws {
        try Self.validate(selectors)
    }

    @Test(arguments: [
        Selectors(app: true, pid: true, windowID: false, windowTitle: false, windowIndex: false),
        Selectors(app: true, pid: true, windowID: true, windowTitle: false, windowIndex: false),
        Selectors(app: true, pid: true, windowID: false, windowTitle: true, windowIndex: false),
        Selectors(app: true, pid: true, windowID: false, windowTitle: false, windowIndex: true),
    ])
    func `app and pid combinations fail closed`(_ selectors: Selectors) {
        #expect(throws: InteractionTargetSelectorValidationError.applicationAndProcessIdentifier) {
            try Self.validate(selectors)
        }
    }

    @Test(arguments: [
        Selectors(app: true, pid: false, windowID: true, windowTitle: true, windowIndex: false),
        Selectors(app: true, pid: false, windowID: true, windowTitle: false, windowIndex: true),
        Selectors(app: true, pid: false, windowID: false, windowTitle: true, windowIndex: true),
        Selectors(app: true, pid: false, windowID: true, windowTitle: true, windowIndex: true),
    ])
    func `multiple window selectors fail closed`(_ selectors: Selectors) {
        #expect(throws: InteractionTargetSelectorValidationError.multipleWindowSelectors) {
            try Self.validate(selectors)
        }
    }

    @Test(arguments: [
        Selectors(app: false, pid: false, windowID: false, windowTitle: true, windowIndex: false),
        Selectors(app: false, pid: false, windowID: false, windowTitle: false, windowIndex: true),
    ])
    func `relative window selectors require an application owner`(_ selectors: Selectors) {
        #expect(throws: InteractionTargetSelectorValidationError.windowSelectorRequiresApplication) {
            try Self.validate(selectors)
        }
    }

    private static func validate(_ selectors: Selectors) throws {
        try InteractionTargetSelectorValidator.validate(
            hasApplication: selectors.app,
            hasProcessIdentifier: selectors.pid,
            hasWindowID: selectors.windowID,
            hasWindowTitle: selectors.windowTitle,
            hasWindowIndex: selectors.windowIndex)
    }
}
