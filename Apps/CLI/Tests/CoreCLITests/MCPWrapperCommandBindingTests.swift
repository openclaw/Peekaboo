import Commander
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCLI
@testable import PeekabooCore

struct MCPWrapperCommandBindingTests {
    @Test
    func `MCP server runtime binding exposes foreground opt in`() throws {
        let flag = try #require(MCPCommand.Serve.commanderSignature().flags.first {
            $0.label == "allowForeground"
        })
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: MCPCommand.Serve.self,
            parsedValues: ParsedValues(
                positional: [],
                options: [:],
                flags: ["allowForeground"]
            )
        )

        #expect(flag.names.contains(.long("allow-foreground")))
        #expect(command.allowForeground)
    }

    @Test
    func `Browser command binding`() throws {
        let parsed = ParsedValues(
            positional: ["navigate"],
            options: [
                "channel": ["stable"],
                "browserUrl": ["http://127.0.0.1:9222"],
                "url": ["https://example.com"],
                "timeout": ["5000"],
                "types": ["error,warning", "info"],
                "resourceTypes": ["script", "xhr"],
            ],
            flags: ["bringToFront", "foreground", "includeSnapshot", "noReload"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: BrowserCommand.self, parsedValues: parsed)
        #expect(command.action == "navigate")
        #expect(command.channel == "stable")
        #expect(command.browserUrl == "http://127.0.0.1:9222")
        #expect(command.url == "https://example.com")
        #expect(command.timeout?.roundedMilliseconds == 5000)
        #expect(command.types == ["error", "warning", "info"])
        #expect(command.resourceTypes == ["script", "xhr"])
        #expect(command.bringToFront == true)
        #expect(command.foreground == true)
        #expect(command.includeSnapshot == true)
        #expect(command.noReload == true)
    }

    @Test
    func `Browser command rejects contradictory foreground flags`() {
        #expect(throws: ValidationError.self) {
            _ = try CommanderCLIBinder.instantiateCommand(
                ofType: BrowserCommand.self,
                parsedValues: ParsedValues(
                    positional: ["new-page"],
                    options: ["url": ["https://example.com"]],
                    flags: ["background", "foreground"]
                )
            )
        }

        #expect(throws: ValidationError.self) {
            _ = try CommanderCLIBinder.instantiateCommand(
                ofType: BrowserCommand.self,
                parsedValues: ParsedValues(
                    positional: ["select-page"],
                    options: ["pageId": ["1"]],
                    flags: ["bringToFront", "noBringToFront"]
                )
            )
        }
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
        #expect(command.toolExecutionPolicy == .backgroundOnly)
        #expect(!command.runtimeOptions.requiresImplicitSnapshotInvalidation)
        #expect(!command.runtimeOptions.usesPerToolSnapshotInvalidation)
    }

    @Test
    func `Browser command requires explicit foreground authority for connect`() throws {
        let background = try CommanderCLIBinder.instantiateCommand(
            ofType: BrowserCommand.self,
            parsedValues: ParsedValues(positional: ["connect"], options: [:], flags: [])
        )
        let foreground = try CommanderCLIBinder.instantiateCommand(
            ofType: BrowserCommand.self,
            parsedValues: ParsedValues(positional: ["connect"], options: [:], flags: ["foreground"])
        )

        #expect(background.toolExecutionPolicy == .backgroundOnly)
        #expect(foreground.toolExecutionPolicy == .foregroundAllowed)
        #expect(!background.runtimeOptions.requiresImplicitSnapshotInvalidation)
        #expect(background.runtimeOptions.usesPerToolSnapshotInvalidation)
        #expect(!foreground.runtimeOptions.requiresImplicitSnapshotInvalidation)
        #expect(foreground.runtimeOptions.usesPerToolSnapshotInvalidation)
    }

    @Test
    func `Browser command derives runtime mutation tracking from mapped provider calls`() throws {
        let sourceProvenReads: [ParsedValues] = [
            ParsedValues(positional: ["console"], options: ["pageId": ["1"]], flags: []),
            ParsedValues(
                positional: ["network"],
                options: ["pageId": ["1"], "requestId": ["1"]],
                flags: []
            ),
            ParsedValues(positional: ["screenshot"], options: ["pageId": ["1"]], flags: []),
        ]

        for parsed in sourceProvenReads {
            let command = try CommanderCLIBinder.instantiateCommand(
                ofType: BrowserCommand.self,
                parsedValues: parsed
            )
            #expect(!command.runtimeOptions.requiresImplicitSnapshotInvalidation)
            #expect(!command.runtimeOptions.usesPerToolSnapshotInvalidation)
            #expect(!command.runtimeOptions.dynamicToolScreenCaptureReachable)
        }

        let foregroundOnlyReads: [ParsedValues] = [
            ParsedValues(positional: ["list-pages"], options: [:], flags: []),
            ParsedValues(
                positional: ["wait-for"],
                options: ["pageId": ["1"], "text": ["ready"]],
                flags: []
            ),
            ParsedValues(positional: ["snapshot"], options: ["pageId": ["1"]], flags: []),
        ]
        for parsed in foregroundOnlyReads {
            let command = try CommanderCLIBinder.instantiateCommand(
                ofType: BrowserCommand.self,
                parsedValues: parsed
            )
            #expect(!command.runtimeOptions.requiresImplicitSnapshotInvalidation)
            #expect(command.runtimeOptions.usesPerToolSnapshotInvalidation)
            #expect(!command.runtimeOptions.dynamicToolScreenCaptureReachable)
        }

        let selectedWithoutFronting = try CommanderCLIBinder.instantiateCommand(
            ofType: BrowserCommand.self,
            parsedValues: ParsedValues(
                positional: ["select-page"],
                options: ["pageId": ["1"]],
                flags: []
            )
        )
        let selectedWithFronting = try CommanderCLIBinder.instantiateCommand(
            ofType: BrowserCommand.self,
            parsedValues: ParsedValues(
                positional: ["select-page"],
                options: ["pageId": ["1"]],
                flags: ["bringToFront"]
            )
        )

        #expect(selectedWithoutFronting.runtimeOptions.usesPerToolSnapshotInvalidation)
        #expect(selectedWithFronting.runtimeOptions.usesPerToolSnapshotInvalidation)
        #expect(!selectedWithFronting.runtimeOptions.requiresImplicitSnapshotInvalidation)
        #expect(!selectedWithFronting.runtimeOptions.dynamicToolScreenCaptureReachable)
    }

    @Test
    func `See tree command binding`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "app": ["TextEdit"],
                "snapshot": ["snapshot-123"],
                "depth": ["4"],
                "maxElements": ["200"],
                "maxChildren": ["20"],
            ],
            flags: ["tree", "noScreenshot"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: SeeCommand.self, parsedValues: parsed)
        #expect(command.app == "TextEdit")
        #expect(command.depth == 4)
        #expect(command.maxElements == 200)
        #expect(command.maxChildren == 20)
        #expect(command.tree)
        #expect(command.noScreenshot)
        #expect(command.runtimeOptions.requiresInspectAccessibilityTree == true)
    }

    @Test
    @MainActor
    func `MCP server context shares capture refusal and execution gate with nested agent`() throws {
        let services = PeekabooServices()
        let gate = MCPToolSnapshotExecutionGate()
        let refusal = MCPToolCapturePreflightRefusal(
            message: "fixture capture refusal",
            hint: "start a fresh MCP session"
        )
        let agent = try PeekabooAgentService(
            services: services,
            snapshotExecutionGate: gate
        )
        services.agent = agent

        let context = MCPCommand.Serve.makeToolContext(
            services: services,
            snapshotMutationCoordinator: nil,
            capturePreflightRefusal: refusal
        )
        let nestedAgentContext = agent.makeToolContext()

        #expect(context.snapshotExecutionGate === gate)
        #expect(context.snapshotExecutionGate === agent.snapshotExecutionGate)
        #expect(context.capturePreflightRefusal == refusal)
        #expect(context.executionPolicy == .backgroundOnly)
        #expect(nestedAgentContext.capturePreflightRefusal == refusal)
        #expect(nestedAgentContext.executionPolicy == .backgroundOnly)

        let foregroundContext = MCPCommand.Serve.makeToolContext(
            services: services,
            snapshotMutationCoordinator: nil,
            executionPolicy: .foregroundAllowed
        )
        #expect(foregroundContext.executionPolicy == .foregroundAllowed)
    }
}
