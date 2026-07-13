import Commander
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCLI
@testable import PeekabooCore

struct MCPWrapperCommandBindingTests {
    @Test
    func `Browser command binding`() throws {
        let parsed = ParsedValues(
            positional: ["navigate"],
            options: [
                "channel": ["chrome"],
                "url": ["https://example.com"],
                "timeout": ["5000"],
                "types": ["error,warning", "info"],
                "resourceTypes": ["script", "xhr"],
            ],
            flags: ["background", "includeSnapshot", "noReload"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: BrowserCommand.self, parsedValues: parsed)
        #expect(command.action == "navigate")
        #expect(command.channel == "chrome")
        #expect(command.url == "https://example.com")
        #expect(command.timeout == 5000)
        #expect(command.types == ["error", "warning", "info"])
        #expect(command.resourceTypes == ["script", "xhr"])
        #expect(command.background == true)
        #expect(command.includeSnapshot == true)
        #expect(command.noReload == true)
    }

    @Test
    func `Browser command requires remote browser MCP capability`() throws {
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: BrowserCommand.self,
            parsedValues: ParsedValues(positional: [], options: [:], flags: [])
        )

        #expect(command.runtimeOptions.requiresBrowserMCP == true)
    }

    @Test
    func `Browser command defaults to status`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let command = try CommanderCLIBinder.instantiateCommand(ofType: BrowserCommand.self, parsedValues: parsed)
        #expect(command.action == "status")
    }

    @Test
    func `Inspect UI command binding`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "app": ["TextEdit"],
                "snapshot": ["snapshot-123"],
                "maxDepth": ["4"],
                "maxElements": ["200"],
                "maxChildren": ["20"],
            ],
            flags: []
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: InspectUICommand.self, parsedValues: parsed)
        #expect(command.appTarget == "TextEdit")
        #expect(command.snapshot == "snapshot-123")
        #expect(command.maxDepth == 4)
        #expect(command.maxElements == 200)
        #expect(command.maxChildren == 20)
    }

    @Test
    func `Inspect UI command preserves app target alias`() throws {
        let parsed = ParsedValues(positional: [], options: ["appTarget": ["TextEdit"]], flags: [])
        let command = try CommanderCLIBinder.instantiateCommand(ofType: InspectUICommand.self, parsedValues: parsed)
        #expect(command.appTarget == "TextEdit")
    }

    @Test
    func `Inspect UI command rejects both app spellings`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: ["app": ["TextEdit"], "appTarget": ["Finder"]],
            flags: []
        )
        #expect(throws: ValidationError.self) {
            _ = try CommanderCLIBinder.instantiateCommand(ofType: InspectUICommand.self, parsedValues: parsed)
        }
    }

    @Test
    func `Inspect UI command requires remote inspect capability`() throws {
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: InspectUICommand.self,
            parsedValues: ParsedValues(positional: [], options: [:], flags: [])
        )

        #expect(command.runtimeOptions.requiresInspectAccessibilityTree == true)
        #expect(command.runtimeOptions.requiresImplicitSnapshotInvalidation == false)
        #expect(command.runtimeOptions.usesPerToolSnapshotInvalidation == true)
    }

    @Test
    @MainActor
    func `MCP server context shares the nested agent execution gate`() throws {
        let services = PeekabooServices()
        let gate = MCPToolSnapshotExecutionGate()
        let agent = try PeekabooAgentService(
            services: services,
            snapshotExecutionGate: gate
        )
        services.agent = agent

        let context = MCPCommand.Serve.makeToolContext(
            services: services,
            snapshotMutationCoordinator: nil
        )

        #expect(context.snapshotExecutionGate === gate)
        #expect(context.snapshotExecutionGate === agent.snapshotExecutionGate)
    }
}
