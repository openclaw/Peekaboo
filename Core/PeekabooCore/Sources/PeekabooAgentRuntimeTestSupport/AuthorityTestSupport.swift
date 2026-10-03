import PeekabooAgentRuntime
import PeekabooAutomation
import PeekabooCore
import PeekabooFoundationTestSupport
import Tachikoma

@MainActor
public enum AuthorityTestSupport {
    public static func prepare() throws {
        let credentialKeys = Provider.standardProviders.flatMap {
            [$0.environmentVariable] + $0.alternativeEnvironmentVariables
        } + ["OPENAI_ACCESS_TOKEN", "ANTHROPIC_ACCESS_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "PEEKABOO_AI_PROVIDERS"]
        try AgentTestStorage.prepare(forbiddenEnvironmentKeys: credentialKeys) {
            let configuration = TachikomaConfiguration(loadFromEnvironment: false)
            configuration.setProviderFactoryOverride { model, _ in
                guard case let .custom(provider) = model else {
                    throw AgentTestStorage.IsolationError.realProviderForbidden
                }
                return provider
            }
            TachikomaConfiguration.default = configuration
        }
    }

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
