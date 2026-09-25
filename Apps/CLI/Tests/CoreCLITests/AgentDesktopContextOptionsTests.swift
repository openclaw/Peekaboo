import Commander
import PeekabooAgentRuntime
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
struct AgentDesktopContextOptionsTests {
    @Test(arguments: [false, true])
    func `all execution modes bind the desktop context choice`(disabled: Bool) throws {
        let arguments = disabled ? ["--no-desktop-context"] : []
        let shorthand = try AgentCommand.parse(["Inspect synthetic controls"] + arguments)
        let run = try AgentRunSubcommand.parse(["Inspect synthetic controls"] + arguments)
        let chat = try AgentChatSubcommand.parse(arguments)
        let resume = try AgentResumeSubcommand.parse(arguments)
        var commands = [shorthand]
        for options in [run.options, chat.options, resume.options] {
            var command = AgentCommand()
            options.apply(to: &command)
            commands.append(command)
        }

        for command in commands {
            #expect(command.noDesktopContext == disabled)
            #expect(command.enhancementOptions.contextAware == !disabled)
            #expect(command.newSessionToolExecutionPolicy == .backgroundOnly)
            #expect(command.requestedResumeToolExecutionPolicy == .backgroundOnly)
            Self.expectOtherDefaults(command.enhancementOptions)
        }
    }

    @Test
    func `context opt out does not grant or revoke foreground authority`() throws {
        let command = try AgentCommand.parse(["--no-desktop-context", "--allow-foreground"])
        #expect(command.enhancementOptions.contextAware == false)
        #expect(command.newSessionToolExecutionPolicy == .foregroundAllowed)
        #expect(command.requestedResumeToolExecutionPolicy == .foregroundAllowed)
        Self.expectOtherDefaults(command.enhancementOptions)
    }

    @Test
    func `each execution mode advertises the context opt out`() {
        for help in [
            AgentRootCommand.helpMessage(),
            AgentRunSubcommand.helpMessage(),
            AgentChatSubcommand.helpMessage(),
            AgentResumeSubcommand.helpMessage(),
        ] {
            #expect(help.contains("--no-desktop-context"))
            #expect(help.contains("saved history"))
        }
        #expect(!AgentSessionsSubcommand.helpMessage().contains("--no-desktop-context"))
    }

    private static func expectOtherDefaults(_ options: AgentEnhancementOptions) {
        let defaults = AgentEnhancementOptions.default
        #expect(options.verifyActions == defaults.verifyActions)
        #expect(options.maxVerificationRetries == defaults.maxVerificationRetries)
        #expect(options.verifyActionTypes == defaults.verifyActionTypes)
        #expect(options.smartCapture == defaults.smartCapture)
        #expect(options.changeThreshold == defaults.changeThreshold)
        #expect(options.regionFocusAfterAction == defaults.regionFocusAfterAction)
        #expect(options.regionCaptureRadius == defaults.regionCaptureRadius)
    }
}
