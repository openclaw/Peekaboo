import PeekabooAgentRuntime
import PeekabooAutomation
import PeekabooCore
import PeekabooFoundationTestSupport
import Tachikoma

@MainActor
public enum AuthorityTestSupport {
    public static func services(snapshotManager: (any SnapshotManagerProtocol)? = nil) -> PeekabooServices {
        PeekabooServices(
            snapshotManager: snapshotManager ?? InMemorySnapshotManager(),
            initializeAgentService: false)
    }

    public static func agent(
        services: any PeekabooServiceProviding,
        defaultModel: LanguageModel = .anthropic(.opus5),
        snapshotMutationCoordinator: (any MCPToolSnapshotMutationCoordinating)? = nil,
        snapshotExecutionGate: MCPToolSnapshotExecutionGate = MCPToolSnapshotExecutionGate(),
        sessionManager: AgentSessionManager? = nil) throws -> PeekabooAgentService
    {
        try PeekabooAgentService(
            services: services,
            defaultModel: defaultModel,
            snapshotMutationCoordinator: snapshotMutationCoordinator,
            snapshotExecutionGate: snapshotExecutionGate,
            sessionManager: sessionManager ??
                AgentSessionManager(sessionDirectory: AgentTestStorage.sessionDirectory()))
    }
}
