import PeekabooAutomation
import PeekabooFoundationTestSupport
import Tachikoma
import Testing

/// Isolate synthetic authority suites from process configuration. Participating tests must run with --no-parallel.
public struct AuthorityTestIsolation: TestTrait, SuiteTrait, TestScoping {
    public typealias TestBody = @concurrent @Sendable () async throws -> Void

    public init() {}

    public func provideScope(
        for _: Test,
        testCase _: Test.Case?,
        performing function: TestBody) async throws
    {
        let scope = try await MainActor.run { try Scope() }
        do {
            try await function()
        } catch {
            try await MainActor.run { try scope.restore() }
            throw error
        }
        try await MainActor.run { try scope.restore() }
    }

    @MainActor
    private struct Scope {
        let configuration: TachikomaConfiguration?
        let profileDirectoryName: String
        let storage: AgentTestStorage.Scope

        init() throws {
            self.configuration = TachikomaConfiguration.default
            self.profileDirectoryName = TachikomaConfiguration.profileDirectoryName
            let credentialKeys = Provider.standardProviders.flatMap {
                [$0.environmentVariable] + $0.alternativeEnvironmentVariables
            } + ["OPENAI_ACCESS_TOKEN", "ANTHROPIC_ACCESS_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "PEEKABOO_AI_PROVIDERS"]
            self.storage = try AgentTestStorage.install(forbiddenEnvironmentKeys: credentialKeys)
            #if DEBUG
            ConfigurationManager.shared.resetForTesting()
            #endif
            // Point Tachikoma's credential lookup at the empty root now, not on the next lazy configuration load.
            ConfigurationManager.configureTachikomaProfileDirectory()
            let configuration = TachikomaConfiguration(loadFromEnvironment: false)
            configuration.setProviderFactoryOverride { model, _ in
                guard case let .custom(provider) = model else {
                    throw AgentTestStorage.IsolationError.realProviderForbidden
                }
                return provider
            }
            TachikomaConfiguration.default = configuration
        }

        func restore() throws {
            defer {
                TachikomaConfiguration.default = self.configuration
                #if DEBUG
                ConfigurationManager.shared.resetForTesting()
                #endif
                TachikomaConfiguration.profileDirectoryName = self.profileDirectoryName
            }
            try AgentTestStorage.restore(self.storage)
        }
    }
}
