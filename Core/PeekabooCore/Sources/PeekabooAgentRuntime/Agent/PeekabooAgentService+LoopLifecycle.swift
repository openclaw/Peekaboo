import Foundation
import Tachikoma

@available(macOS 14.0, *)
@MainActor
extension PeekabooAgentService {
    func withAgentEventDelivery(
        task: String,
        delegate: any AgentEventDelegate,
        operation: (EventHandler?) async throws -> AgentExecutionResult) async throws -> AgentExecutionResult
    {
        let continuation: AsyncStream<AgentEvent>.Continuation?
        let consumer: Task<Void, Never>?
        let handler: EventHandler?
        if delegate.receivesAgentEvents {
            let (events, eventContinuation) = AsyncStream<AgentEvent>.makeStream()
            continuation = eventContinuation
            // Unstructured so execution cancellation cannot discard queued delegate callbacks.
            consumer = Task { @MainActor in
                delegate.agentDidEmitEvent(.started(task: task))
                for await event in events {
                    delegate.agentDidEmitEvent(event)
                }
            }
            handler = EventHandler { event in eventContinuation.yield(event) }
        } else {
            continuation = nil
            consumer = nil
            handler = nil
        }

        let outcome: Result<AgentExecutionResult, any Error>
        do {
            let result = try await operation(handler)
            await handler?.send(.completed(summary: result.content, usage: result.usage))
            outcome = .success(result)
        } catch {
            if !(error is CancellationError) {
                await handler?.send(.error(message: error.localizedDescription))
            }
            outcome = .failure(error)
        }
        continuation?.finish()
        await consumer?.value
        return try outcome.get()
    }

    struct AgentPhaseTiming {
        enum Phase: String {
            case providerStream = "provider_stream"
            case providerGenerate = "provider_generate"
            case tool
        }

        enum Status: String {
            case success
            case error
            case cancelled
        }

        let phase: Phase
        let stepIndex: Int
        let elapsedMilliseconds: Double
        let status: Status

        var logMessage: String {
            "phase=\(self.phase.rawValue) step=\(self.stepIndex) " +
                "elapsed_ms=\(self.elapsedMilliseconds) status=\(self.status.rawValue)"
        }
    }

    func withAgentPhaseTiming<T>(
        _ phase: AgentPhaseTiming.Phase,
        stepIndex: Int,
        resultIsFailure: (T) -> Bool = { _ in false },
        operation: () async throws -> T) async rethrows -> T
    {
        let startedAt = ContinuousClock.now
        var status = AgentPhaseTiming.Status.success
        defer {
            let elapsed = startedAt.duration(to: .now).components
            let timing = AgentPhaseTiming(
                phase: phase,
                stepIndex: stepIndex,
                elapsedMilliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
                status: status)
            self.logger.debug("\(timing.logMessage, privacy: .public)")
            self.phaseTimingObserver?(timing)
        }
        do {
            let result = try await operation()
            let failed = resultIsFailure(result)
            if Task.isCancelled {
                status = .cancelled
            } else if failed {
                status = .error
            }
            return result
        } catch {
            status = self.isAgentCancellation(error) ? .cancelled : .error
            throw error
        }
    }

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

    func contentByAppendingTurnBoundaryReason(
        _ stopReason: String,
        to content: String) -> String
    {
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReason = stopReason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedReason.isEmpty else { return normalizedContent }
        guard !normalizedContent.isEmpty else { return normalizedReason }

        if normalizedContent == normalizedReason || normalizedContent.hasSuffix("\n\(normalizedReason)") {
            return normalizedContent
        }
        return "\(normalizedContent)\n\n\(normalizedReason)"
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

    func logStepCompletion(
        stepIndex: Int,
        stepText: String,
        toolCalls: [AgentToolCall])
    {
        guard self.isVerbose else { return }
        self.logger.debug(
            "Step \(stepIndex) completed: collected \(toolCalls.count) tool calls, text length: \(stepText.count)")
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
