import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
struct AgentChatLaunchPolicyTests {
    private let policy = AgentChatLaunchPolicy()

    private func makeCaps(
        interactive: Bool = true,
        inputInteractive: Bool? = nil,
        piped: Bool = false,
        ci: Bool = false
    ) -> TerminalCapabilities {
        TerminalCapabilities(
            isInputInteractive: inputInteractive ?? interactive,
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

    @Test
    func `Piped input does not opt a fresh taskless command into chat based on stdout`() {
        let strategy = self.policy.strategy(
            for: AgentChatLaunchContext(
                chatFlag: false,
                hasTaskInput: false,
                listSessions: false,
                normalizedTaskInput: nil,
                capabilities: self.makeCaps(interactive: true, inputInteractive: false)
            )
        )

        #expect(strategy == .helpOnly)
    }

    @Test
    @MainActor
    func `Only automatic noninteractive resume propagates turn failures`() throws {
        let tasklessResume = try AgentCommand.parse(["--resume"])
        let interactiveResume = try AgentCommand.parse(["--resume"])
        let explicitChat = try AgentCommand.parse(["--resume", "--chat"])
        let oneShotResume = try AgentCommand.parse(["Continue", "--resume"])

        #expect(tasklessResume.shouldFailTasklessResumeTurn(
            capabilities: self.makeCaps(interactive: true, inputInteractive: false)
        ))
        #expect(!interactiveResume.shouldFailTasklessResumeTurn(capabilities: self.makeCaps()))
        #expect(!explicitChat.shouldFailTasklessResumeTurn(
            capabilities: self.makeCaps(interactive: false, piped: true)
        ))
        #expect(!oneShotResume.shouldFailTasklessResumeTurn(
            capabilities: self.makeCaps(interactive: false, piped: true)
        ))
    }

    @Test
    @MainActor
    func `Automatic CI resume avoids TauTUI while explicit chat can opt in`() throws {
        let capabilities = self.makeCaps(interactive: true, inputInteractive: true, ci: true)
        let automaticResume = try AgentCommand.parse(["--resume"])
        let explicitChat = try AgentCommand.parse(["--resume", "--chat"])

        #expect(!automaticResume.shouldUseTauTUIChat(capabilities: capabilities))
        #expect(explicitChat.shouldUseTauTUIChat(capabilities: capabilities))
    }
}
