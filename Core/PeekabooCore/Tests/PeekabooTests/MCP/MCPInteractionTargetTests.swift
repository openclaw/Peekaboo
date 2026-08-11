import PeekabooAutomation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

struct MCPInteractionTargetTests {
    @MainActor
    @Test
    func `background app target retains its discovered process generation`() async throws {
        let expected = ApplicationProcessIdentity(processIdentifier: 4242, processStartIdentity: 71)
        let applications = MockApplicationService(applications: [ServiceApplicationInfo(
            processIdentifier: expected.processIdentifier,
            processStartIdentity: expected.processStartIdentity,
            bundleIdentifier: "com.example.editor",
            name: "Editor")])
        let context = await MCPToolTestHelpers.makeContext(applications: applications)
        let target = try Self.makeTarget(Selectors(
            app: "Editor",
            pid: nil,
            windowTitle: nil,
            windowIndex: nil,
            windowID: nil))

        let identity = try await target.requireBackgroundProcessIdentity(
            applications: context.applications,
            windows: context.windows)

        #expect(identity == expected)
    }

    @MainActor
    @Test
    func `background app target refuses missing process generation`() async throws {
        let applications = MockApplicationService(applications: [ServiceApplicationInfo(
            processIdentifier: 4242,
            bundleIdentifier: "com.example.editor",
            name: "Editor")])
        let context = await MCPToolTestHelpers.makeContext(applications: applications)
        let target = try Self.makeTarget(Selectors(
            app: "Editor",
            pid: nil,
            windowTitle: nil,
            windowIndex: nil,
            windowID: nil))

        await #expect(throws: MCPInteractionTargetError.targetProcessIdentityUnavailable) {
            _ = try await target.requireBackgroundProcessIdentity(
                applications: context.applications,
                windows: context.windows)
        }
    }

    enum InvalidConsumerFixture: CaseIterable, Sendable {
        case applicationAndPID
        case windowIDAndTitle
        case titleWithoutOwner
        case indexWithoutOwner

        var arguments: [String: Any] {
            switch self {
            case .applicationAndPID:
                ["app": "Preview", "pid": 42]
            case .windowIDAndTitle:
                ["app": "Preview", "window_id": 7, "window_title": "Main"]
            case .titleWithoutOwner:
                ["window_title": "Main"]
            case .indexWithoutOwner:
                ["window_index": 2]
            }
        }

        var message: String {
            switch self {
            case .applicationAndPID:
                "app and pid are mutually exclusive"
            case .windowIDAndTitle:
                "window_id, window_title, and window_index are mutually exclusive"
            case .titleWithoutOwner, .indexWithoutOwner:
                "require app or pid"
            }
        }
    }

    struct Selectors: Sendable {
        let app: String?
        let pid: Int?
        let windowTitle: String?
        let windowIndex: Int?
        let windowID: Int?
    }

    @Test(arguments: [
        Selectors(app: nil, pid: nil, windowTitle: nil, windowIndex: nil, windowID: nil),
        Selectors(app: "Preview", pid: nil, windowTitle: nil, windowIndex: nil, windowID: nil),
        Selectors(app: nil, pid: 42, windowTitle: nil, windowIndex: nil, windowID: nil),
        Selectors(app: nil, pid: nil, windowTitle: nil, windowIndex: nil, windowID: 7),
        Selectors(app: "Preview", pid: nil, windowTitle: "Main", windowIndex: nil, windowID: nil),
        Selectors(app: nil, pid: 42, windowTitle: "Main", windowIndex: nil, windowID: nil),
        Selectors(app: "Preview", pid: nil, windowTitle: nil, windowIndex: 2, windowID: nil),
        Selectors(app: nil, pid: 42, windowTitle: nil, windowIndex: 2, windowID: nil),
    ])
    func `valid selector combinations construct`(_ selectors: Selectors) throws {
        _ = try Self.makeTarget(selectors)
    }

    @Test(arguments: [
        Selectors(app: "Preview", pid: 42, windowTitle: nil, windowIndex: nil, windowID: nil),
        Selectors(app: "PID:42", pid: 42, windowTitle: nil, windowIndex: nil, windowID: nil),
        Selectors(app: "Preview", pid: 42, windowTitle: nil, windowIndex: nil, windowID: 7),
    ])
    func `app and pid fail closed during construction`(_ selectors: Selectors) {
        #expect(throws: MCPInteractionTargetError.applicationAndProcessIdentifier) {
            _ = try Self.makeTarget(selectors)
        }
    }

    @Test(arguments: [
        Selectors(app: "Preview", pid: nil, windowTitle: "Main", windowIndex: nil, windowID: 7),
        Selectors(app: "Preview", pid: nil, windowTitle: nil, windowIndex: 2, windowID: 7),
        Selectors(app: "Preview", pid: nil, windowTitle: "Main", windowIndex: 2, windowID: nil),
        Selectors(app: "Preview", pid: nil, windowTitle: "Main", windowIndex: 2, windowID: 7),
    ])
    func `multiple window selectors fail closed during construction`(_ selectors: Selectors) {
        #expect(throws: MCPInteractionTargetError.multipleWindowSelectors) {
            _ = try Self.makeTarget(selectors)
        }
    }

    @Test(arguments: [
        Selectors(app: nil, pid: nil, windowTitle: "Main", windowIndex: nil, windowID: nil),
        Selectors(app: nil, pid: nil, windowTitle: nil, windowIndex: 2, windowID: nil),
    ])
    func `relative window selectors require an owner during construction`(_ selectors: Selectors) {
        #expect(throws: MCPInteractionTargetError.windowSelectorRequiresApp) {
            _ = try Self.makeTarget(selectors)
        }
    }

    @Test(arguments: [
        Selectors(app: nil, pid: 0, windowTitle: nil, windowIndex: nil, windowID: nil),
        Selectors(app: nil, pid: Int(Int32.max) + 1, windowTitle: nil, windowIndex: nil, windowID: nil),
    ])
    func `invalid process identifiers fail during construction`(_ selectors: Selectors) {
        #expect(throws: MCPInteractionTargetError.invalidProcessIdentifier) {
            _ = try Self.makeTarget(selectors)
        }
    }

    @Test(arguments: [
        Selectors(app: nil, pid: nil, windowTitle: nil, windowIndex: nil, windowID: 0),
        Selectors(app: nil, pid: nil, windowTitle: nil, windowIndex: nil, windowID: Int(UInt32.max) + 1),
    ])
    func `invalid window identifiers fail during construction`(_ selectors: Selectors) {
        #expect(throws: MCPInteractionTargetError.invalidWindowId) {
            _ = try Self.makeTarget(selectors)
        }
    }

    @Test
    func `negative window index fails during construction`() {
        #expect(throws: MCPInteractionTargetError.invalidWindowIndex) {
            _ = try Self.makeTarget(Selectors(
                app: "Preview",
                pid: nil,
                windowTitle: nil,
                windowIndex: -1,
                windowID: nil))
        }
    }

    @Test
    func `valid title target retains its owner`() throws {
        let target = try Self.makeTarget(Selectors(
            app: "Preview",
            pid: nil,
            windowTitle: "Main",
            windowIndex: nil,
            windowID: nil))

        switch try target.toWindowTarget() {
        case let .applicationAndTitle(app, title):
            #expect(app == "Preview")
            #expect(title == "Main")
        default:
            Issue.record("Expected application title target")
        }
    }

    @MainActor
    @Test(arguments: InvalidConsumerFixture.allCases)
    func `all MCP interaction consumers reject invalid selectors before execution`(
        fixture: InvalidConsumerFixture) async throws
    {
        let context = await MCPToolTestHelpers.makeContext()
        let arguments = fixture.arguments
        let responses = try await [
            TypeTool(context: context).execute(arguments: ToolArguments(raw: arguments.merging([
                "text": "hello",
            ]) { current, _ in current })),
            PressTool(context: context).execute(arguments: ToolArguments(raw: arguments.merging([
                "keys": ["cmd+c"],
            ]) { current, _ in current })),
            PasteTool(context: context).execute(arguments: ToolArguments(raw: arguments.merging([
                "text": "hello",
            ]) { current, _ in current })),
            DialogTool(context: context).execute(arguments: ToolArguments(raw: arguments.merging([
                "action": "list",
            ]) { current, _ in current })),
        ]

        for response in responses {
            #expect(response.isError)
            guard case let .text(text, _, _)? = response.content.first else {
                Issue.record("Expected selector validation error")
                continue
            }
            #expect(text.contains(fixture.message))
        }
    }

    private static func makeTarget(_ selectors: Selectors) throws -> MCPInteractionTarget {
        try MCPInteractionTarget(
            app: selectors.app,
            pid: selectors.pid,
            windowTitle: selectors.windowTitle,
            windowIndex: selectors.windowIndex,
            windowId: selectors.windowID)
    }
}
