import Foundation

// MARK: - Audio Content

/// Represents audio content in a conversation message
public struct AudioContent: Codable, Sendable {
    public let data: Data?
    public let duration: TimeInterval?
    public let transcript: String?
    public let format: String?

    public init(
        data: Data? = nil,
        duration: TimeInterval? = nil,
        transcript: String? = nil,
        format: String? = nil)
    {
        self.data = data
        self.duration = duration
        self.transcript = transcript
        self.format = format
    }
}

// MARK: - Conversation Session Models

/// Represents a conversation session with an AI agent
public struct ConversationSession: Identifiable, Codable, Sendable {
    public let id: String
    public var title: String
    public var messages: [ConversationMessage]
    public let startTime: Date
    public var summary: String
    public var modelName: String

    public init(
        id: String? = nil,
        title: String,
        messages: [ConversationMessage] = [],
        startTime: Date = Date(),
        summary: String = "",
        modelName: String = "")
    {
        self.id = id ?? "session_\(UUID().uuidString)"
        self.title = title
        self.messages = messages
        self.startTime = startTime
        self.summary = summary
        self.modelName = modelName
    }
}

/// Represents a message in a conversation
public struct ConversationMessage: Identifiable, Codable, Sendable {
    public let id: UUID
    public let role: MessageRole
    public let content: String
    public let timestamp: Date
    public var toolCalls: [ConversationToolCall]
    public let audioContent: AudioContent?

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        timestamp: Date = Date(),
        toolCalls: [ConversationToolCall] = [],
        audioContent: AudioContent? = nil)
    {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.toolCalls = toolCalls
        self.audioContent = audioContent
    }
}

/// Message role in a conversation
public enum MessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
}

/// Represents a tool call in a conversation
public struct ConversationToolCall: Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
    public let arguments: String
    public var result: String

    public init(
        id: String? = nil,
        name: String,
        arguments: String,
        result: String = "")
    {
        self.id = id ?? UUID().uuidString
        self.name = name
        self.arguments = arguments
        self.result = result
    }
}

// MARK: - Session Summary

/// Summary information about a conversation session
public struct ConversationSessionSummary: Identifiable, Sendable {
    // Create a new session
    public let id: String
    public let title: String
    public let startTime: Date
    public let messageCount: Int
    public let lastMessageTime: Date?
    public let modelName: String

    public init(from session: ConversationSession) {
        self.id = session.id
        self.title = session.title
        self.startTime = session.startTime
        self.messageCount = session.messages.count
        self.lastMessageTime = session.messages.last?.timestamp
        self.modelName = session.modelName
    }
}
