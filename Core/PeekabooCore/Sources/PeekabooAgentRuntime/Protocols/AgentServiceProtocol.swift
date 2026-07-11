import Foundation
import PeekabooAutomation
import PeekabooFoundation
import Tachikoma

public enum AgentStepBudget {
    public static let supportedRange = 1...100

    public static func validate(_ maxSteps: Int) throws -> Int {
        guard self.supportedRange.contains(maxSteps) else {
            throw PeekabooError.invalidInput(
                "Maximum agent steps must be between \(self.supportedRange.lowerBound) and " +
                    "\(self.supportedRange.upperBound); received \(maxSteps).")
        }
        return maxSteps
    }
}

/// Protocol defining the agent service interface
@available(macOS 14.0, *)
@MainActor
public protocol AgentServiceProtocol: Sendable {
    /// Execute a task using the AI agent
    /// - Parameters:
    ///   - task: The task description
    ///   - maxSteps: Maximum number of reasoning steps (default: 20)
    ///   - dryRun: If true, simulates execution without performing actions
    ///   - eventDelegate: Optional delegate for real-time event updates
    /// - Returns: The agent execution result
    func executeTask(
        _ task: String,
        maxSteps: Int,
        dryRun: Bool,
        queueMode: QueueMode,
        eventDelegate: (any AgentEventDelegate)?) async throws -> AgentExecutionResult

    /// Execute a task with audio content
    /// - Parameters:
    ///   - audioContent: The audio content to process
    ///   - maxSteps: Maximum number of reasoning steps (default: 20)
    ///   - dryRun: If true, simulates execution without performing actions
    ///   - eventDelegate: Optional delegate for real-time event updates
    /// - Returns: The agent execution result
    func executeTaskWithAudio(
        audioContent: AudioContent,
        maxSteps: Int,
        dryRun: Bool,
        queueMode: QueueMode,
        eventDelegate: (any AgentEventDelegate)?) async throws -> AgentExecutionResult

    /// Clean up any cached sessions or resources
    func cleanup() async
}
