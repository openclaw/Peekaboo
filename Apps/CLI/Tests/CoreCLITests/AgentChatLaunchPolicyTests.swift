import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
struct AgentChatLaunchPolicyTests {
    private let policy = AgentChatLaunchPolicy()

    private func makeCaps(
        interactive: Bool = true,
        piped: Bool = false,
        ci: Bool = false
    ) -> TerminalCapabilities {
        TerminalCapabilities(
            isInteractive: interactive,
            supportsColors: true,
            supportsTrueColor: false,
            width: 80,
            height: 24,
            termType: "xterm-256color",
            isCI: ci,
            isPiped: piped
        )
    }

    @Test
    func `Chat flag forces interactive with initial prompt`() {
        let strategy = self.policy.strategy(
            for: AgentChatLaunchContext(
                chatFlag: true,
                hasTaskInput: false,
                listSessions: false,
                normalizedTaskInput: "hello",
                capabilities: self.makeCaps()
            )
        )

        if case let .interactive(initialPrompt) = strategy {
            #expect(initialPrompt == "hello")
        } else {
            Issue.record("Expected interactive strategy")
        }
    }

    @Test
    func `Task input skips auto chat`() {
        let strategy = self.policy.strategy(
            for: AgentChatLaunchContext(
                chatFlag: false,
                hasTaskInput: true,
                listSessions: false,
                normalizedTaskInput: "task",
                capabilities: self.makeCaps()
            )
        )

        #expect(strategy == .none)
    }

    @Test
    func `Interactive terminal defaults to chat`() {
        let strategy = self.policy.strategy(
            for: AgentChatLaunchContext(
                chatFlag: false,
                hasTaskInput: false,
                listSessions: false,
                normalizedTaskInput: nil,
                capabilities: self.makeCaps()
            )
        )

        #expect(strategy == .interactive(initialPrompt: nil))
    }

    @Test
    func `CI or piped output shows help only`() {
        let piped = self.policy.strategy(
            for: AgentChatLaunchContext(
                chatFlag: false,
                hasTaskInput: false,
                listSessions: false,
                normalizedTaskInput: nil,
                capabilities: self.makeCaps(interactive: false, piped: true)
            )
        )

        #expect(piped == .helpOnly)

        let ci = self.policy.strategy(
            for: AgentChatLaunchContext(
                chatFlag: false,
                hasTaskInput: false,
                listSessions: false,
                normalizedTaskInput: nil,
                capabilities: self.makeCaps(ci: true)
            )
        )

        #expect(ci == .helpOnly)
    }

    @Test
    func `Taskless session resume enters chat even without an interactive terminal`() {
        let strategy = self.policy.strategy(
            for: AgentChatLaunchContext(
                chatFlag: false,
                hasTaskInput: false,
                listSessions: false,
                normalizedTaskInput: nil,
                capabilities: self.makeCaps(interactive: false, piped: true),
                hasSessionResumption: true
            )
        )

        #expect(strategy == .interactive(initialPrompt: nil))
    }
}
