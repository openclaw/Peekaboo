/// Value-only selector input that can be mapped into Foundation, CLI, or MCP target types.
public struct InteractionTargetSelectorCase: Equatable, Sendable {
    public enum ExpectedFailure: Equatable, Sendable {
        case applicationAndProcessIdentifier
        case multipleWindowSelectors
        case windowSelectorRequiresApplication
    }

    public let hasApplication: Bool
    public let hasProcessIdentifier: Bool
    public let hasWindowID: Bool
    public let hasWindowTitle: Bool
    public let hasWindowIndex: Bool
    public let expectedFailure: ExpectedFailure?
}

public enum InteractionTargetSelectorFixtures {
    public static let validCases: [InteractionTargetSelectorCase] = [
        InteractionTargetSelectorFixtures.make(),
        InteractionTargetSelectorFixtures.make(app: true),
        InteractionTargetSelectorFixtures.make(pid: true),
        InteractionTargetSelectorFixtures.make(windowID: true),
        InteractionTargetSelectorFixtures.make(app: true, windowID: true),
        InteractionTargetSelectorFixtures.make(pid: true, windowID: true),
        InteractionTargetSelectorFixtures.make(app: true, title: true),
        InteractionTargetSelectorFixtures.make(pid: true, title: true),
        InteractionTargetSelectorFixtures.make(app: true, index: true),
        InteractionTargetSelectorFixtures.make(pid: true, index: true),
    ]

    public static let applicationAndProcessIdentifierCases = [
        InteractionTargetSelectorFixtures.make(app: true, pid: true, failure: .applicationAndProcessIdentifier),
        InteractionTargetSelectorFixtures.make(
            app: true, pid: true, windowID: true, failure: .applicationAndProcessIdentifier),
        InteractionTargetSelectorFixtures.make(
            app: true,
            pid: true,
            title: true,
            failure: .applicationAndProcessIdentifier),
        InteractionTargetSelectorFixtures.make(
            app: true,
            pid: true,
            index: true,
            failure: .applicationAndProcessIdentifier),
    ]

    public static let multipleWindowSelectorCases = [
        InteractionTargetSelectorFixtures.make(
            app: true, windowID: true, title: true, failure: .multipleWindowSelectors),
        InteractionTargetSelectorFixtures.make(
            app: true, windowID: true, index: true, failure: .multipleWindowSelectors),
        InteractionTargetSelectorFixtures.make(app: true, title: true, index: true, failure: .multipleWindowSelectors),
        InteractionTargetSelectorFixtures.make(
            app: true, windowID: true, title: true, index: true, failure: .multipleWindowSelectors),
    ]

    public static let windowSelectorRequiresApplicationCases = [
        InteractionTargetSelectorFixtures.make(title: true, failure: .windowSelectorRequiresApplication),
        InteractionTargetSelectorFixtures.make(index: true, failure: .windowSelectorRequiresApplication),
    ]

    private static func make(
        app: Bool = false,
        pid: Bool = false,
        windowID: Bool = false,
        title: Bool = false,
        index: Bool = false,
        failure: InteractionTargetSelectorCase.ExpectedFailure? = nil) -> InteractionTargetSelectorCase
    {
        InteractionTargetSelectorCase(
            hasApplication: app,
            hasProcessIdentifier: pid,
            hasWindowID: windowID,
            hasWindowTitle: title,
            hasWindowIndex: index,
            expectedFailure: failure)
    }
}
