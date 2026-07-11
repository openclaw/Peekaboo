//
//  AgentChatLaunchPolicy.swift
//  PeekabooCLI
//

import Foundation

enum ChatLaunchStrategy: Equatable {
    case none
    case helpOnly
    case interactive(initialPrompt: String?)
}

struct AgentChatLaunchContext {
    let chatFlag: Bool
    let hasTaskInput: Bool
    let listSessions: Bool
    let normalizedTaskInput: String?
    let capabilities: TerminalCapabilities
    let hasSessionResumption: Bool

    init(
        chatFlag: Bool,
        hasTaskInput: Bool,
        listSessions: Bool,
        normalizedTaskInput: String?,
        capabilities: TerminalCapabilities,
        hasSessionResumption: Bool = false
    ) {
        self.chatFlag = chatFlag
        self.hasTaskInput = hasTaskInput
        self.listSessions = listSessions
        self.normalizedTaskInput = normalizedTaskInput
        self.capabilities = capabilities
        self.hasSessionResumption = hasSessionResumption
    }
}

/// Determines how the agent should launch chat mode based on flags and terminal context.
@available(macOS 14.0, *)
struct AgentChatLaunchPolicy {
    func strategy(for context: AgentChatLaunchContext) -> ChatLaunchStrategy {
        if context.chatFlag {
            return .interactive(initialPrompt: context.normalizedTaskInput)
        }

        if context.hasTaskInput || context.listSessions {
            return .none
        }

        if context.hasSessionResumption {
            return .interactive(initialPrompt: nil)
        }

        if context.capabilities.isInteractive && !context.capabilities.isPiped && !context.capabilities.isCI {
            return .interactive(initialPrompt: nil)
        }

        return .helpOnly
    }
}
