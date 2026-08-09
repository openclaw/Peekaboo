import Foundation
import Tachikoma

@available(macOS 14.0, *)
@MainActor
extension PeekabooAgentService {
    enum AgentToolImageLifecycleError: Error {
        case executionAlreadyActive(String)
    }

    func withAgentToolImageLifecycle<T: Sendable>(
        executionID: String,
        imageStore: AgentToolMCPImageStore,
        operation: @MainActor () async throws -> T) async throws -> T
    {
        guard await imageStore.register(executionID: executionID) else {
            throw AgentToolImageLifecycleError.executionAlreadyActive(executionID)
        }
        do {
            let value = try await operation()
            await imageStore.close(executionID: executionID)
            return value
        } catch {
            await imageStore.close(executionID: executionID)
            throw error
        }
    }

    func makeLoopOutcome(
        state: StreamingLoopState,
        reachedStepLimit: Bool) -> StreamingLoopOutcome
    {
        StreamingLoopOutcome(
            content: state.content,
            messages: state.messages.removingConsumedAgentToolImageContext(),
            steps: state.steps,
            usage: state.usage,
            toolCallCount: state.toolCallCount,
            reachedStepLimit: reachedStepLimit)
    }

    func logStreamingStepStart(_ stepIndex: Int, tools: [AgentTool]) {
        guard self.isVerbose else { return }

        self.logger.debug("Step \(stepIndex): Passing \(tools.count) tools to streamText")
        if tools.isEmpty {
            self.logger.warning("No tools available!")
            return
        }

        let toolNames = tools.map(\.name).joined(separator: ", ")
        self.logger.debug("Available tools: \(toolNames)")
    }

    func isAgentCancellation(_ error: any Error) -> Bool {
        if Task.isCancelled || error is CancellationError {
            return true
        }
        if (error as? URLError)?.code == .cancelled {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return true
        }

        if let tachikomaError = error as? TachikomaError {
            switch tachikomaError {
            case let .networkError(underlyingError):
                return self.isAgentCancellation(underlyingError)
            case let .retryError(retryError):
                if let lastError = retryError.lastError,
                   self.isAgentCancellation(lastError)
                {
                    return true
                }
                return retryError.errors.contains { self.isAgentCancellation($0) }
            default:
                break
            }
        }

        if let unifiedError = error as? TachikomaUnifiedError,
           let underlyingError = unifiedError.underlyingError
        {
            return self.isAgentCancellation(underlyingError)
        }

        if let modelError = error as? ModelError,
           case let .networkError(underlyingError) = modelError
        {
            return self.isAgentCancellation(underlyingError)
        }

        return false
    }
}
