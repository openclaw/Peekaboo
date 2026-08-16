import Foundation
import PeekabooFoundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@MainActor
struct AgentTurnBoundaryTranscriptTests {
    @Test
    func `turn boundary appends tool results for all advertised tool calls`() async throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        var messages: [ModelMessage] = []
        let toolCalls = [
            AgentToolCall(id: "see-call", name: "see", arguments: [:]),
            AgentToolCall(id: "click-call", name: "click", arguments: [:]),
            AgentToolCall(id: "type-call", name: "type", arguments: [:]),
        ]
        let tools = ["see", "click", "type"].map { name in
            AgentTool(
                name: name,
                description: name,
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in AnyAgentToolValue(string: "\(name)-ok") })
        }
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: tools,
            eventHandler: nil,
            sessionId: "test-session",
            executionPolicy: .unrestricted)

        let step = try await service.handleToolCalls(
            stepText: "",
            toolCalls: toolCalls,
            context: context,
            currentMessages: &messages,
            stepIndex: 0)

        #expect(step.toolResults.map(\.toolCallId) == ["see-call", "click-call", "type-call"])
        #expect(step.toolResults.count == toolCalls.count)
        #expect(step.toolResults[2].isError)

        let toolMessages = messages.filter { $0.role == .tool }
        #expect(toolMessages.count == toolCalls.count)

        guard let skippedJSON = try? step.toolResults[2].result.toJSON() as? [String: Any] else {
            Issue.record("Expected skipped result to encode as an object")
            return
        }
        #expect(skippedJSON["skipped"] as? Bool == true)
        #expect((skippedJSON["reason"] as? String)?.contains("click") == true)
        #expect(service.turnBoundarySignal(from: step.toolResults) == .continueNextStep(
            reason: "Stopped after click; call `see` again before the next UI action."))
        #expect(service.turnBoundaryStopReason(from: step.toolResults) == nil)

        let skippedBoundary = try #require(skippedJSON["turn_boundary"] as? [String: Any])
        #expect(skippedBoundary["continue_next_step"] as? Bool == true)
        #expect(skippedBoundary["stop_after_current_step"] as? Bool == true)
    }

    @Test
    func `canonical browser outcome ends the provider step only after dispatch`() async throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        var messages: [ModelMessage] = []
        let browserOutcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted)
        let browserResult = try Self.canonicalResult(browserOutcome)
        let toolCalls = [
            AgentToolCall(id: "browser-call", name: "browser", arguments: [
                "action": AnyAgentToolValue(string: "click"),
            ]),
            AgentToolCall(id: "later-call", name: "later", arguments: [:]),
        ]
        let tools = [
            AgentTool(
                name: "browser",
                description: "browser",
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in browserResult }),
            AgentTool(
                name: "later",
                description: "later",
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in AnyAgentToolValue(string: "must-not-run") }),
        ]
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: tools,
            eventHandler: nil,
            sessionId: "test-session",
            executionPolicy: .unrestricted)

        let step = try await service.handleToolCalls(
            stepText: "",
            toolCalls: toolCalls,
            context: context,
            currentMessages: &messages,
            stepIndex: 0)

        #expect(step.toolResults.count == 2)
        #expect(service.turnBoundarySignal(from: step.toolResults) == .continueNextStep(
            reason: "Stopped after browser; call `see` before the next UI action."))
        let skipped = try #require(try step.toolResults[1].result.toJSON() as? [String: Any])
        #expect(skipped["skipped"] as? Bool == true)
    }

    @Test
    func `canonical browser failure outcome ends the provider step after possible dispatch`() async throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        var messages: [ModelMessage] = []
        let outcome = DesktopActionOutcome.indeterminate(
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .completionUnknown)
        let browserFailure = try AgentToolExecutionFailure(
            message: "browser completion unknown",
            metadata: Self.canonicalResult(outcome))
        let tools = [
            AgentTool(
                name: "browser",
                description: "browser",
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in throw browserFailure }),
            AgentTool(
                name: "later",
                description: "later",
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in AnyAgentToolValue(string: "must-not-run") }),
        ]
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: tools,
            eventHandler: nil,
            sessionId: "test-session",
            executionPolicy: .unrestricted)

        let step = try await service.handleToolCalls(
            stepText: "",
            toolCalls: [
                AgentToolCall(id: "browser-call", name: "browser", arguments: [:]),
                AgentToolCall(id: "later-call", name: "later", arguments: [:]),
            ],
            context: context,
            currentMessages: &messages,
            stepIndex: 0)

        #expect(step.toolResults.count == 2)
        #expect(service.turnBoundarySignal(from: step.toolResults) == .continueNextStep(
            reason: "Stopped after browser; call `see` before the next UI action."))
        #expect(step.toolResults[1].isError)
    }

    @Test
    func `resumed browser failure restores perception debt from failure metadata`() throws {
        let call = AgentToolCall(id: "browser-failure", name: "browser", arguments: [
            "action": AnyAgentToolValue(string: "click"),
        ])
        let outcome = DesktopActionOutcome.indeterminate(
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one)
        let result = try AgentToolResult(
            toolCallId: call.id,
            failure: AgentToolExecutionFailure(
                message: "Browser completion is unknown",
                metadata: Self.canonicalResult(outcome)))

        let restored = PeekabooAgentService.restoredTurnBoundary(from: [
            ModelMessage(role: .assistant, content: [.toolCall(call)]),
            ModelMessage(role: .tool, content: [.toolResult(result)]),
        ])

        #expect(restored.record(toolName: "click") == .skipUntilPerception(
            reason: "Skipped click; call `see` successfully before another UI action."))
    }

    @Test
    func `background app launch readiness failure ends the live provider step after dispatch`() async throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        var messages: [ModelMessage] = []
        let outcome = DesktopActionOutcome.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one)
        let readinessFailure = try AgentToolExecutionFailure(
            message: "App launch readiness is unknown",
            metadata: Self.canonicalResult(outcome))
        let tools = [
            AgentTool(
                name: "app",
                description: "app",
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in throw readinessFailure }),
            AgentTool(
                name: "click",
                description: "click",
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in AnyAgentToolValue(string: "must-not-run") }),
        ]
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: tools,
            eventHandler: nil,
            sessionId: "test-session",
            executionPolicy: .unrestricted)

        let step = try await service.handleToolCalls(
            stepText: "",
            toolCalls: [
                AgentToolCall(id: "app-call", name: "app", arguments: [
                    "action": AnyAgentToolValue(string: "launch"),
                    "name": AnyAgentToolValue(string: "TextEdit"),
                ]),
                AgentToolCall(id: "click-call", name: "click", arguments: [:]),
            ],
            context: context,
            currentMessages: &messages,
            stepIndex: 0)

        #expect(step.toolResults.count == 2)
        #expect(service.turnBoundarySignal(from: step.toolResults) == .continueNextStep(
            reason: "Stopped after app; call `see` before the next UI action."))
        #expect(step.toolResults[1].isError)
    }

    @Test
    func `resumed background app launch readiness failure restores perception debt`() throws {
        let call = AgentToolCall(id: "app-failure", name: "app", arguments: [
            "action": AnyAgentToolValue(string: "launch"),
            "name": AnyAgentToolValue(string: "TextEdit"),
        ])
        let outcome = DesktopActionOutcome.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one)
        let result = try AgentToolResult(
            toolCallId: call.id,
            failure: AgentToolExecutionFailure(
                message: "App launch readiness is unknown",
                metadata: Self.canonicalResult(outcome)))

        let restored = PeekabooAgentService.restoredTurnBoundary(from: [
            ModelMessage(role: .assistant, content: [.toolCall(call)]),
            ModelMessage(role: .tool, content: [.toolResult(result)]),
        ])

        #expect(restored.record(toolName: "click") == .skipUntilPerception(
            reason: "Skipped click; call `see` successfully before another UI action."))
    }

    @Test
    func `canonical browser pre-dispatch refusal does not skip later calls`() async throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        var messages: [ModelMessage] = []
        let refusal = DesktopActionOutcome.refused(reason: .targetUnavailable)
        let browserFailure = try AgentToolExecutionFailure(
            message: "browser target changed",
            metadata: Self.canonicalResult(refusal))
        let tools = [
            AgentTool(
                name: "browser",
                description: "browser",
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in throw browserFailure }),
            AgentTool(
                name: "later",
                description: "later",
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in AnyAgentToolValue(string: "ran") }),
        ]
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: tools,
            eventHandler: nil,
            sessionId: "test-session",
            executionPolicy: .unrestricted)

        let step = try await service.handleToolCalls(
            stepText: "",
            toolCalls: [
                AgentToolCall(id: "browser-call", name: "browser", arguments: [:]),
                AgentToolCall(id: "later-call", name: "later", arguments: [:]),
            ],
            context: context,
            currentMessages: &messages,
            stepIndex: 0)

        #expect(step.toolResults.count == 2)
        #expect(step.toolResults[1].result.stringValue == "ran")
        #expect(service.turnBoundarySignal(from: step.toolResults) == nil)
    }

    @Test
    func `legacy persisted stop marker remains terminal`() throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        let legacy = AgentToolResult(
            toolCallId: "legacy-call",
            result: AnyAgentToolValue(object: [
                "turn_boundary": AnyAgentToolValue(object: [
                    "stop_after_current_step": AnyAgentToolValue(bool: true),
                    "reason": AnyAgentToolValue(string: "Legacy terminal boundary"),
                ]),
            ]),
            isError: false)

        #expect(service.turnBoundarySignal(from: legacy) == .stopAgent(reason: "Legacy terminal boundary"))
        #expect(service.turnBoundaryStopReason(from: legacy) == "Legacy terminal boundary")
    }

    @Test
    func `turn boundary conflict matrix stops conservatively while compatible forms agree`() throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        let continueBoundary = AnyAgentToolValue(object: [
            "continue_next_step": AnyAgentToolValue(bool: true),
            "disposition": AnyAgentToolValue(string: "continue_next_step"),
            "reason": AnyAgentToolValue(string: "Continue after observation"),
            "stop_after_current_step": AnyAgentToolValue(bool: true),
        ])
        let stopBoundary = AnyAgentToolValue(object: [
            "disposition": AnyAgentToolValue(string: "stop_agent"),
            "reason": AnyAgentToolValue(string: "Stop after failure"),
            "stop_after_current_step": AnyAgentToolValue(bool: true),
            "stop_agent": AnyAgentToolValue(bool: true),
        ])
        let conflictingCases: [(String, AnyAgentToolValue, AnyAgentToolValue)] = [
            ("continue-then-stop", continueBoundary, stopBoundary),
            ("stop-then-continue", stopBoundary, continueBoundary),
            (
                "reason-disagreement",
                continueBoundary,
                AnyAgentToolValue(object: [
                    "continue_next_step": AnyAgentToolValue(bool: true),
                    "reason": AnyAgentToolValue(string: "Different continuation reason"),
                ])),
            ("malformed-nested", continueBoundary, AnyAgentToolValue(string: "not an object")),
        ]

        for (name, rootBoundary, nestedBoundary) in conflictingCases {
            let result = AgentToolResult.success(
                toolCallId: name,
                result: AnyAgentToolValue(object: [
                    "metadata": AnyAgentToolValue(object: ["turn_boundary": nestedBoundary]),
                    "turn_boundary": rootBoundary,
                ]))
            let claims = AgentToolResultSemantics.normalizedClaims(from: result.result)
            let restored = PeekabooAgentService.restoredTurnBoundary(from: [
                ModelMessage(role: .tool, content: [.toolResult(result)]),
            ])

            #expect(claims.turnBoundary == .invalid, "Expected conflict for \(name)")
            #expect(AgentToolResultSemantics.isFailure(result))
            #expect(service.turnBoundarySignal(from: result) == .stopAgent(
                reason: PeekabooAgentService.invalidTurnBoundaryReason))
            #expect(restored.record(toolName: "click") == .skipUntilPerception(
                reason: "Skipped click; call `see` successfully before another UI action."))
        }

        let malformedSingleBoundaries: [(String, AnyAgentToolValue)] = [
            ("empty", AnyAgentToolValue(object: [:])),
            ("reason-only", AnyAgentToolValue(object: [
                "reason": AnyAgentToolValue(string: "No disposition"),
            ])),
            ("false-flags", AnyAgentToolValue(object: [
                "continue_next_step": AnyAgentToolValue(bool: false),
                "reason": AnyAgentToolValue(string: "No positive disposition"),
                "stop_after_current_step": AnyAgentToolValue(bool: false),
                "stop_agent": AnyAgentToolValue(bool: false),
            ])),
        ]
        for (name, boundary) in malformedSingleBoundaries {
            let result = AgentToolResult.success(
                toolCallId: name,
                result: AnyAgentToolValue(object: ["turn_boundary": boundary]))
            #expect(AgentToolResultSemantics.normalizedClaims(from: result.result).turnBoundary == .invalid)
            #expect(service.turnBoundarySignal(from: result) == .stopAgent(
                reason: PeekabooAgentService.invalidTurnBoundaryReason))
        }

        let compatible = AgentToolResult.success(
            toolCallId: "compatible-boundary",
            result: AnyAgentToolValue(object: [
                "metadata": AnyAgentToolValue(object: [
                    "turn_boundary": AnyAgentToolValue(object: [
                        "continue_next_step": AnyAgentToolValue(bool: true),
                        "reason": AnyAgentToolValue(string: "Continue after observation"),
                    ]),
                ]),
                "turn_boundary": AnyAgentToolValue(object: [
                    "disposition": AnyAgentToolValue(string: "continue_next_step"),
                    "reason": AnyAgentToolValue(string: "Continue after observation"),
                    "stop_after_current_step": AnyAgentToolValue(bool: true),
                ]),
            ]))
        #expect(service.turnBoundarySignal(from: compatible) == .continueNextStep(
            reason: "Continue after observation"))

        let malformedAfterContinue = AgentToolResult.success(
            toolCallId: "malformed-after-continue",
            result: AnyAgentToolValue(object: [
                "turn_boundary": AnyAgentToolValue(object: [
                    "reason": AnyAgentToolValue(string: "Missing disposition"),
                ]),
            ]))
        let stopAfterContinue = AgentToolResult.success(
            toolCallId: "stop-after-continue",
            result: AnyAgentToolValue(object: [
                "turn_boundary": stopBoundary,
            ]))
        #expect(service.turnBoundarySignal(from: [compatible, malformedAfterContinue]) == .stopAgent(
            reason: PeekabooAgentService.invalidTurnBoundaryReason))
        #expect(service.turnBoundarySignal(from: [compatible, stopAfterContinue]) == .stopAgent(
            reason: "Stop after failure"))
    }

    @Test
    func `unavailable advertised tool calls still receive tool results`() async throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        var messages: [ModelMessage] = []
        let toolCalls = [
            AgentToolCall(id: "known-call", name: "known", arguments: [:]),
            AgentToolCall(id: "missing-call", name: "missing", arguments: [:]),
        ]
        let tools = [
            AgentTool(
                name: "known",
                description: "known",
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in AnyAgentToolValue(string: "known-ok") }),
        ]
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: tools,
            eventHandler: nil,
            sessionId: "test-session",
            executionPolicy: .unrestricted)

        let step = try await service.handleToolCalls(
            stepText: "",
            toolCalls: toolCalls,
            context: context,
            currentMessages: &messages,
            stepIndex: 0)

        #expect(step.toolResults.map(\.toolCallId) == ["known-call", "missing-call"])
        #expect(step.toolResults[1].isError)
        #expect(messages.count(where: { $0.role == .tool }) == toolCalls.count)
    }

    @Test
    func `tool execution cancellation escapes tool handling`() async throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        var messages: [ModelMessage] = []
        let toolCalls = [
            AgentToolCall(id: "click-call", name: "click", arguments: [:]),
        ]
        let tools = [
            AgentTool(
                name: "click",
                description: "click",
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in throw CancellationError() }),
        ]
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: tools,
            eventHandler: nil,
            sessionId: "test-session",
            executionPolicy: .unrestricted)

        var cancelled = false
        do {
            _ = try await service.handleToolCalls(
                stepText: "",
                toolCalls: toolCalls,
                context: context,
                currentMessages: &messages,
                stepIndex: 0)
        } catch is CancellationError {
            cancelled = true
        }

        #expect(cancelled)
    }

    @Test(.timeLimit(.minutes(1)))
    func `parent cancellation checkpoints completed tools and skips remaining dispatch`() async throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        let probe = ToolCancellationProbe()
        let transcriptStore = CancellationTranscriptStore()
        let toolCalls = [
            AgentToolCall(id: "first-call", name: "first", arguments: [:]),
            AgentToolCall(id: "second-call", name: "second", arguments: [:]),
            AgentToolCall(id: "third-call", name: "third", arguments: [:]),
        ]
        let tools = [
            AgentTool(
                name: "first",
                description: "first",
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in AnyAgentToolValue(string: "first-ok") }),
            AgentTool(
                name: "second",
                description: "second",
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in
                    await probe.markSecondStarted()
                    do {
                        try await Task.sleep(for: .seconds(30))
                    } catch is CancellationError {
                        // Simulate a side effect that completed while ignoring cooperative cancellation.
                    }
                    return AnyAgentToolValue(string: "second-ok")
                }),
            AgentTool(
                name: "third",
                description: "third",
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in
                    await probe.markThirdExecuted()
                    return AnyAgentToolValue(string: "third-ok")
                }),
        ]
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: tools,
            eventHandler: nil,
            sessionId: "test-session",
            executionPolicy: .unrestricted)

        let task = Task { @MainActor () -> CancellationWorkerOutcome in
            var messages: [ModelMessage] = []
            var checkpoint: GenerationStep?
            do {
                _ = try await service.handleToolCalls(
                    stepText: "",
                    toolCalls: toolCalls,
                    context: context,
                    currentMessages: &messages,
                    stepIndex: 0,
                    onCancellationCheckpoint: { checkpoint = $0 })
                return .completed
            } catch {
                await transcriptStore.capture(messages: messages, checkpoint: checkpoint)
                return if error is CancellationError {
                    .cancelled
                } else {
                    .failed(error.localizedDescription)
                }
            }
        }
        let taskObserver = Task {
            let outcome = await task.value
            await probe.markWorkerFinished(outcome)
        }
        defer { taskObserver.cancel() }

        guard await probe.waitForSecondStart(timeout: .seconds(5)) else {
            task.cancel()
            guard await probe.waitForWorkerFinish(timeout: .seconds(5)) != nil else {
                Issue.record("Timed out waiting for the canceled worker to stop")
                return
            }
            Issue.record("Timed out waiting for the second tool to start")
            return
        }
        task.cancel()
        guard let workerOutcome = await probe.waitForWorkerFinish(timeout: .seconds(5)) else {
            Issue.record("Timed out waiting for the canceled worker to stop")
            return
        }
        #expect(workerOutcome == .cancelled)

        let snapshot = await transcriptStore.snapshot()
        let checkpoint = try #require(snapshot.checkpoint)
        #expect(checkpoint.toolResults.map(\.toolCallId) == ["first-call", "second-call", "third-call"])
        #expect(checkpoint.toolResults.map(\.isError) == [false, false, true])
        #expect(snapshot.messages.count(where: { $0.role == .tool }) == toolCalls.count)
        #expect(await probe.thirdExecutionCount == 0)

        let skippedPayload = try #require(try checkpoint.toolResults[2].result.toJSON() as? [String: Any])
        #expect(skippedPayload["cancelled"] as? Bool == true)
        #expect(skippedPayload["skipped"] as? Bool == true)
    }

    @Test
    func `URL cancellation is rethrown and remaining tool calls are not dispatched`() async throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        let probe = ToolCancellationProbe()
        var messages: [ModelMessage] = []
        var checkpoint: GenerationStep?
        let toolCalls = [
            AgentToolCall(id: "cancelled-call", name: "cancelled", arguments: [:]),
            AgentToolCall(id: "never-call", name: "never", arguments: [:]),
        ]
        let tools = [
            AgentTool(
                name: "cancelled",
                description: "cancelled",
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in throw URLError(.cancelled) }),
            AgentTool(
                name: "never",
                description: "never",
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in
                    await probe.markThirdExecuted()
                    return AnyAgentToolValue(string: "unexpected")
                }),
        ]
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: tools,
            eventHandler: nil,
            sessionId: "test-session",
            executionPolicy: .unrestricted)

        await #expect(throws: CancellationError.self) {
            _ = try await service.handleToolCalls(
                stepText: "",
                toolCalls: toolCalls,
                context: context,
                currentMessages: &messages,
                stepIndex: 0,
                onCancellationCheckpoint: { checkpoint = $0 })
        }

        let captured = try #require(checkpoint)
        #expect(captured.toolResults.map(\.toolCallId) == ["cancelled-call", "never-call"])
        #expect(captured.toolResults.map(\.isError) == [true, true])
        #expect(messages.count(where: { $0.role == .tool }) == toolCalls.count)
        #expect(await probe.thirdExecutionCount == 0)
    }

    private static func canonicalResult(_ outcome: DesktopActionOutcome) throws -> AnyAgentToolValue {
        let data = try JSONEncoder().encode(outcome.projection)
        return try AnyAgentToolValue.fromJSON(JSONSerialization.jsonObject(with: data))
    }
}

private enum CancellationWorkerOutcome: Equatable, Sendable {
    case completed
    case cancelled
    case failed(String)
}

private actor ToolCancellationProbe {
    private var secondStarted = false
    private var workerOutcome: CancellationWorkerOutcome?
    private(set) var thirdExecutionCount = 0

    func markSecondStarted() {
        self.secondStarted = true
    }

    func waitForSecondStart(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while !self.secondStarted {
            guard clock.now < deadline else { return false }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return false
            }
        }
        return true
    }

    func markWorkerFinished(_ outcome: CancellationWorkerOutcome) {
        self.workerOutcome = outcome
    }

    func waitForWorkerFinish(timeout: Duration) async -> CancellationWorkerOutcome? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while self.workerOutcome == nil {
            guard clock.now < deadline else { return nil }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return nil
            }
        }
        return self.workerOutcome
    }

    func markThirdExecuted() {
        self.thirdExecutionCount += 1
    }
}

private actor CancellationTranscriptStore {
    private var messages: [ModelMessage] = []
    private var checkpoint: GenerationStep?

    func capture(messages: [ModelMessage], checkpoint: GenerationStep?) {
        self.messages = messages
        self.checkpoint = checkpoint
    }

    func snapshot() -> (messages: [ModelMessage], checkpoint: GenerationStep?) {
        (self.messages, self.checkpoint)
    }
}
