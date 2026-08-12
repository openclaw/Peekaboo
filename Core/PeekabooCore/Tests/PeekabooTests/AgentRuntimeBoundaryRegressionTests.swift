import Foundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
@MainActor
struct AgentRuntimeBoundaryRegressionTests {
    private let model = LanguageModel.anthropic(.opus47)

    @Test
    func `Unbuffered truncated stream cannot execute decoded tool call`() async throws {
        let toolCall = AgentToolCall(id: "truncated-call", name: "probe", arguments: [:])
        let provider = RuntimeBoundaryProvider(
            text: "",
            toolCalls: [toolCall],
            emitsTerminalEvent: false)
        let executions = RuntimeBoundaryCounter()
        let events = RuntimeBoundaryEventRecorder()
        let (service, sessionStore) = try self.makeAgentService()
        defer { sessionStore.cleanup() }
        let configuration = self.configuration(
            provider: provider,
            tools: [self.tool(named: "probe", counter: executions)],
            eventHandler: EventHandler { event in await events.record(event) })

        let error = await #expect(throws: TachikomaError.self) {
            _ = try await service.runStreamingLoop(
                configuration: configuration,
                maxSteps: 1,
                initialMessages: [.user("Run the probe.")])
        }

        #expect(error?.localizedDescription.contains("without a terminal event") == true)
        #expect(await executions.isEmpty)
        #expect(await events.snapshot().isEmpty)
    }

    @Test
    func `Cancellation after streamed starts emits failed completions for every call`() async throws {
        let toolCalls = [
            AgentToolCall(id: "first-call", name: "first", arguments: [:]),
            AgentToolCall(id: "second-call", name: "second", arguments: [:]),
        ]
        let provider = RuntimeBoundaryProvider(text: "", toolCalls: toolCalls)
        let executions = RuntimeBoundaryCounter()
        let events = RuntimeBoundaryEventRecorder()
        let (service, sessionStore) = try self.makeAgentService()
        defer { sessionStore.cleanup() }
        let eventHandler = EventHandler { event in
            await events.record(event)
            if case .toolCallStarted = event {
                withUnsafeCurrentTask { task in task?.cancel() }
            }
        }
        let configuration = self.configuration(
            provider: provider,
            tools: [
                self.tool(named: "first", counter: executions),
                self.tool(named: "second", counter: executions),
            ],
            eventHandler: eventHandler)
        var checkpoint: PeekabooAgentService.StreamingLoopOutcome?

        let task = Task { @MainActor in
            try await service.runStreamingLoop(
                configuration: configuration,
                maxSteps: 1,
                initialMessages: [.user("Run both tools.")],
                onCheckpoint: { checkpoint = $0 })
        }
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        let snapshot = await events.snapshot()
        #expect(snapshot.startedToolNames == ["first", "second"])
        #expect(snapshot.completedTools.map(\.name) == ["first", "second"])
        #expect(await executions.isEmpty)
        #expect(checkpoint?.steps.last?.toolResults.count == 2)
        #expect(checkpoint?.steps.last?.toolResults.allSatisfy(\.isError) == true)

        for completion in snapshot.completedTools {
            let payload = try #require(Self.decodeObject(completion.result))
            #expect(payload["success"] as? Bool == false)
            #expect(payload["cancelled"] as? Bool == true)
            #expect((payload["error"] as? String)?.isEmpty == false)
        }
    }

    @Test
    func `Cancellation from non-streaming tool start skips execution and balances lifecycle`() async throws {
        let toolCall = AgentToolCall(id: "cancelled-call", name: "side-effect", arguments: [:])
        let provider = RuntimeBoundaryProvider(text: "", toolCalls: [toolCall])
        let executions = RuntimeBoundaryCounter()
        let events = RuntimeBoundaryEventRecorder()
        let (service, sessionStore) = try self.makeAgentService()
        defer { sessionStore.cleanup() }
        let eventHandler = EventHandler { event in
            await events.record(event)
            if case .toolCallStarted = event {
                withUnsafeCurrentTask { task in task?.cancel() }
            }
        }
        let configuration = self.configuration(
            provider: provider,
            tools: [self.tool(named: toolCall.name, counter: executions)],
            eventHandler: eventHandler)
        var checkpoint: PeekabooAgentService.StreamingLoopOutcome?

        let task = Task { @MainActor in
            try await service.runGenerationLoop(
                configuration: configuration,
                maxSteps: 1,
                initialMessages: [.user("Run the side effect.")],
                onCheckpoint: { checkpoint = $0 })
        }
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        let snapshot = await events.snapshot()
        #expect(snapshot.startedToolNames == [toolCall.name])
        #expect(snapshot.completedTools.map(\.name) == [toolCall.name])
        #expect(await executions.isEmpty)
        #expect(checkpoint?.steps.last?.toolResults.count == 1)
        #expect(checkpoint?.steps.last?.toolResults.first?.isError == true)

        let completion = try #require(snapshot.completedTools.first)
        let payload = try #require(Self.decodeObject(completion.result))
        #expect(payload["success"] as? Bool == false)
        #expect(payload["cancelled"] as? Bool == true)
        #expect(payload["skipped"] == nil)
        #expect((payload["error"] as? String)?.isEmpty == false)
    }

    @Test(arguments: [false, true])
    func `Terminal done and need info reasons follow prior narration without duplication`(
        _ streaming: Bool) async throws
    {
        let narration = "Preparing the final result."
        let (service, sessionStore) = try self.makeAgentService()
        defer { sessionStore.cleanup() }

        for fixture in RuntimeTerminalFixture.allCases {
            let provider = RuntimeBoundaryProvider(text: narration, toolCalls: [fixture.call])
            let configuration = self.configuration(
                provider: provider,
                tools: [self.tool(named: fixture.call.name)],
                eventHandler: nil)
            let outcome = if streaming {
                try await service.runStreamingLoop(
                    configuration: configuration,
                    maxSteps: 1,
                    initialMessages: [.user("Finish the task.")])
            } else {
                try await service.runGenerationLoop(
                    configuration: configuration,
                    maxSteps: 1,
                    initialMessages: [.user("Finish the task.")])
            }
            let expected = "\(narration)\n\n\(fixture.reason)"

            #expect(outcome.content == expected)
            #expect(service.contentByAppendingTurnBoundaryReason(fixture.reason, to: expected) == expected)
        }
    }

    @Test(arguments: [false, true])
    func `Boundary skipped calls receive balanced failed completion events`(_ streaming: Bool) async throws {
        let doneCall = RuntimeTerminalFixture.done.call
        let skippedCall = AgentToolCall(id: "skipped-call", name: "later", arguments: [:])
        let provider = RuntimeBoundaryProvider(text: "", toolCalls: [doneCall, skippedCall])
        let skippedExecutions = RuntimeBoundaryCounter()
        let events = RuntimeBoundaryEventRecorder()
        let (service, sessionStore) = try self.makeAgentService()
        defer { sessionStore.cleanup() }
        let configuration = self.configuration(
            provider: provider,
            tools: [
                self.tool(named: doneCall.name),
                self.tool(named: skippedCall.name, counter: skippedExecutions),
            ],
            eventHandler: EventHandler { event in await events.record(event) })

        let outcome = if streaming {
            try await service.runStreamingLoop(
                configuration: configuration,
                maxSteps: 1,
                initialMessages: [.user("Finish before the later call.")])
        } else {
            try await service.runGenerationLoop(
                configuration: configuration,
                maxSteps: 1,
                initialMessages: [.user("Finish before the later call.")])
        }

        let snapshot = await events.snapshot()
        #expect(snapshot.startedToolNames == ["done", "later"])
        #expect(snapshot.completedTools.map(\.name) == ["done", "later"])
        #expect(await skippedExecutions.isEmpty)
        #expect(outcome.steps.last?.toolResults.map(\.toolCallId) == ["done-call", "skipped-call"])
        #expect(outcome.steps.last?.toolResults.last?.isError == true)

        let skippedCompletion = try #require(snapshot.completedTools.last)
        let payload = try #require(Self.decodeObject(skippedCompletion.result))
        #expect(payload["success"] as? Bool == false)
        #expect(payload["skipped"] as? Bool == true)
        #expect((payload["error"] as? String)?.isEmpty == false)
    }

    @Test(arguments: [false, true])
    func `Perceive mutation boundaries continue across provider steps until done`(
        _ streaming: Bool) async throws
    {
        let provider = RuntimeBoundarySequenceProvider(steps: [
            .init(toolCalls: [
                AgentToolCall(id: "see-1", name: "see", arguments: [:]),
                AgentToolCall(id: "type-1", name: "type", arguments: [:]),
                AgentToolCall(id: "skipped-click", name: "click", arguments: [:]),
            ]),
            .init(toolCalls: [
                AgentToolCall(id: "see-2", name: "see", arguments: [:]),
                AgentToolCall(id: "click-2", name: "click", arguments: [:]),
            ]),
            .init(toolCalls: [
                AgentToolCall(
                    id: "done-1",
                    name: "done",
                    arguments: ["message": AnyAgentToolValue(string: "Finished cycles")]),
            ]),
        ])
        let executions = RuntimeBoundaryExecutionRecorder()
        let (service, sessionStore) = try self.makeAgentService()
        defer { sessionStore.cleanup() }
        let configuration = self.configuration(
            provider: provider,
            tools: ["see", "type", "click", "done"].map { name in
                AgentTool(
                    name: name,
                    description: name,
                    parameters: AgentToolParameters(properties: [:], required: []),
                    execute: { _ in
                        await executions.record(name)
                        if name == "see" {
                            return try AnyAgentToolValue.fromJSON([
                                "error": NSNull(),
                                "success": true,
                            ])
                        }
                        return AnyAgentToolValue(string: "\(name)-ok")
                    })
            },
            eventHandler: nil)

        let outcome = if streaming {
            try await service.runStreamingLoop(
                configuration: configuration,
                maxSteps: 4,
                initialMessages: [.user("Complete two safe UI cycles.")])
        } else {
            try await service.runGenerationLoop(
                configuration: configuration,
                maxSteps: 4,
                initialMessages: [.user("Complete two safe UI cycles.")])
        }

        #expect(provider.requestCount == 3)
        #expect(provider.requestsContainingContinueBoundary == [false, true, true])
        #expect(provider.continueBoundaryReasons == [
            nil,
            "Stopped after type; call `see` again before the next UI action.",
            "Stopped after click; call `see` again before the next UI action.",
        ])
        #expect(await executions.snapshot() == ["see", "type", "see", "click", "done"])
        #expect(outcome.steps.count == 3)
        #expect(outcome.steps[0].toolResults.map(\.toolCallId) == ["see-1", "type-1", "skipped-click"])
        #expect(outcome.steps[0].toolResults.last?.isError == true)
        #expect(outcome.steps[1].toolResults.map(\.toolCallId) == ["see-2", "click-2"])
        #expect(outcome.steps[2].toolResults.map(\.toolCallId) == ["done-1"])
        #expect(outcome.content == "Finished cycles")
        #expect(!outcome.reachedStepLimit)

        let skippedPayload = try #require(
            try outcome.steps[0].toolResults[2].result.toJSON() as? [String: Any])
        #expect(skippedPayload["skipped"] as? Bool == true)
        let boundary = try #require(skippedPayload["turn_boundary"] as? [String: Any])
        #expect(boundary["continue_next_step"] as? Bool == true)
        #expect(boundary["disposition"] as? String == "continue_next_step")
    }

    @Test(arguments: [false, true])
    func `Initial mutation ends provider step and skips later batched mutations`(
        _ streaming: Bool) async throws
    {
        let provider = RuntimeBoundarySequenceProvider(steps: [
            .init(toolCalls: [
                AgentToolCall(id: "type-1", name: "type", arguments: [:]),
                AgentToolCall(id: "click-1", name: "click", arguments: [:]),
            ]),
            .init(toolCalls: [
                AgentToolCall(id: "see-1", name: "see", arguments: [:]),
            ]),
            .init(toolCalls: [
                AgentToolCall(
                    id: "done-1",
                    name: "done",
                    arguments: ["message": AnyAgentToolValue(string: "Verified")]),
            ]),
        ])
        let executions = RuntimeBoundaryExecutionRecorder()
        let (service, sessionStore) = try self.makeAgentService()
        defer { sessionStore.cleanup() }
        let configuration = self.configuration(
            provider: provider,
            tools: ["type", "click", "see", "done"].map { name in
                AgentTool(
                    name: name,
                    description: name,
                    parameters: AgentToolParameters(properties: [:], required: []),
                    execute: { _ in
                        await executions.record(name)
                        return AnyAgentToolValue(string: "\(name)-ok")
                    })
            },
            eventHandler: nil)

        let outcome = if streaming {
            try await service.runStreamingLoop(
                configuration: configuration,
                maxSteps: 3,
                initialMessages: [.user("Do one mutation at a time.")])
        } else {
            try await service.runGenerationLoop(
                configuration: configuration,
                maxSteps: 3,
                initialMessages: [.user("Do one mutation at a time.")])
        }

        #expect(await executions.snapshot() == ["type", "see", "done"])
        #expect(outcome.content == "Verified")
        #expect(outcome.steps.first?.toolResults.map(\.toolCallId) == ["type-1", "click-1"])
        #expect(outcome.steps.first?.toolResults.map(\.isError) == [false, true])
        #expect(provider.continueBoundaryReasons[1] ==
            "Stopped after type; call `see` before the next UI action.")
        #expect(!outcome.reachedStepLimit)
    }

    @Test(arguments: [false, true])
    func `Replay mutations stay skipped until a fresh successful perception`(
        _ streaming: Bool) async throws
    {
        let provider = RuntimeBoundarySequenceProvider(steps: [
            .init(toolCalls: [
                AgentToolCall(id: "see-1", name: "see", arguments: [:]),
                AgentToolCall(id: "type-1", name: "type", arguments: [:]),
            ]),
            .init(toolCalls: [
                AgentToolCall(id: "see-2", name: "see", arguments: [:]),
                AgentToolCall(id: "type-2", name: "type", arguments: [:]),
            ]),
            .init(toolCalls: [
                AgentToolCall(id: "see-3", name: "see", arguments: [:]),
                AgentToolCall(id: "type-3", name: "type", arguments: [:]),
            ]),
            .init(toolCalls: [
                AgentToolCall(id: "replay-type", name: "type", arguments: [:]),
                AgentToolCall(id: "replay-set", name: "set_value", arguments: [:]),
                AgentToolCall(id: "see-4", name: "see", arguments: [:]),
                AgentToolCall(id: "click-4", name: "click", arguments: [:]),
            ]),
            .init(toolCalls: [
                AgentToolCall(
                    id: "done-1",
                    name: "done",
                    arguments: ["message": AnyAgentToolValue(string: "Verified")]),
            ]),
        ])
        let executions = RuntimeBoundaryExecutionRecorder()
        let (service, sessionStore) = try self.makeAgentService()
        defer { sessionStore.cleanup() }
        let configuration = self.configuration(
            provider: provider,
            tools: ["see", "type", "set_value", "click", "done"].map { name in
                AgentTool(
                    name: name,
                    description: name,
                    parameters: AgentToolParameters(properties: [:], required: []),
                    execute: { _ in
                        await executions.record(name)
                        if name == "see" {
                            return try AnyAgentToolValue.fromJSON([
                                "error": NSNull(),
                                "success": true,
                            ])
                        }
                        return AnyAgentToolValue(string: "\(name)-ok")
                    })
            },
            eventHandler: nil)

        let outcome = if streaming {
            try await service.runStreamingLoop(
                configuration: configuration,
                maxSteps: 6,
                initialMessages: [.user("Complete the receiver task without replaying mutations.")])
        } else {
            try await service.runGenerationLoop(
                configuration: configuration,
                maxSteps: 6,
                initialMessages: [.user("Complete the receiver task without replaying mutations.")])
        }

        #expect(await executions.snapshot() == [
            "see", "type", "see", "type", "see", "type", "see", "click", "done",
        ])
        #expect(outcome.content == "Verified")
        #expect(outcome.steps.count == 5)
        let replayResults = outcome.steps[3].toolResults
        #expect(replayResults.map(\.toolCallId) == ["replay-type", "replay-set", "see-4", "click-4"])
        #expect(replayResults.map(\.isError) == [true, true, false, false])
        for skipped in replayResults.prefix(2) {
            let payload = try #require(try skipped.result.toJSON() as? [String: Any])
            #expect(payload["skipped"] as? Bool == true)
            #expect(payload["retry_safe"] as? Bool == true)
            #expect(payload["perception_required"] as? Bool == true)
            #expect(payload["turn_boundary"] == nil)
        }
    }

    @Test(arguments: [false, true])
    func `Resumed loops preserve the perception requirement`(_ streaming: Bool) async throws {
        let executions = RuntimeBoundaryExecutionRecorder()
        let (service, sessionStore) = try self.makeAgentService()
        defer { sessionStore.cleanup() }
        let tools = ["see", "type", "click", "done"].map { name in
            AgentTool(
                name: name,
                description: name,
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in
                    await executions.record(name)
                    if name == "see" {
                        return try AnyAgentToolValue.fromJSON(["error": NSNull(), "success": true])
                    }
                    return AnyAgentToolValue(string: "\(name)-ok")
                })
        }
        let initialProvider = RuntimeBoundarySequenceProvider(steps: [
            .init(toolCalls: [
                AgentToolCall(id: "see-1", name: "see", arguments: [:]),
                AgentToolCall(id: "type-1", name: "type", arguments: [:]),
            ]),
        ])
        let initialConfiguration = self.configuration(
            provider: initialProvider,
            tools: tools,
            eventHandler: nil)
        let initialOutcome = if streaming {
            try await service.runStreamingLoop(
                configuration: initialConfiguration,
                maxSteps: 1,
                initialMessages: [.user("Start the safe UI sequence.")])
        } else {
            try await service.runGenerationLoop(
                configuration: initialConfiguration,
                maxSteps: 1,
                initialMessages: [.user("Start the safe UI sequence.")])
        }

        #expect(initialOutcome.reachedStepLimit)
        #expect(await executions.snapshot() == ["see", "type"])

        let resumedProvider = RuntimeBoundarySequenceProvider(steps: [
            .init(toolCalls: [
                AgentToolCall(id: "replayed-type", name: "type", arguments: [:]),
                AgentToolCall(id: "see-2", name: "see", arguments: [:]),
                AgentToolCall(id: "click-2", name: "click", arguments: [:]),
            ]),
            .init(toolCalls: [
                AgentToolCall(
                    id: "done-1",
                    name: "done",
                    arguments: ["message": AnyAgentToolValue(string: "Resumed safely")]),
            ]),
        ])
        let resumedConfiguration = self.configuration(
            provider: resumedProvider,
            tools: tools,
            eventHandler: nil)
        let resumedOutcome = if streaming {
            try await service.runStreamingLoop(
                configuration: resumedConfiguration,
                maxSteps: 2,
                initialMessages: initialOutcome.messages)
        } else {
            try await service.runGenerationLoop(
                configuration: resumedConfiguration,
                maxSteps: 2,
                initialMessages: initialOutcome.messages)
        }

        #expect(await executions.snapshot() == ["see", "type", "see", "click", "done"])
        #expect(resumedOutcome.content == "Resumed safely")
        let resumedResults = try #require(resumedOutcome.steps.first?.toolResults)
        #expect(resumedResults.map(\.toolCallId) == ["replayed-type", "see-2", "click-2"])
        #expect(resumedResults.map(\.isError) == [true, false, false])
        let replayPayload = try #require(try resumedResults[0].result.toJSON() as? [String: Any])
        #expect(replayPayload["perception_required"] as? Bool == true)
        #expect(replayPayload["skipped"] as? Bool == true)
    }

    @Test(arguments: [false, true])
    func `Failed perception does not rearm mutation dispatch`(_ streaming: Bool) async throws {
        let provider = RuntimeBoundarySequenceProvider(steps: [
            .init(toolCalls: [
                AgentToolCall(id: "see-1", name: "see", arguments: [:]),
                AgentToolCall(id: "type-1", name: "type", arguments: [:]),
            ]),
            .init(toolCalls: [
                AgentToolCall(
                    id: "failed-see",
                    name: "see",
                    arguments: ["fail": AnyAgentToolValue(bool: true)]),
                AgentToolCall(id: "blocked-type", name: "type", arguments: [:]),
            ]),
            .init(toolCalls: [
                AgentToolCall(id: "see-2", name: "see", arguments: [:]),
                AgentToolCall(id: "click-2", name: "click", arguments: [:]),
            ]),
            .init(toolCalls: [
                AgentToolCall(
                    id: "done-1",
                    name: "done",
                    arguments: ["message": AnyAgentToolValue(string: "Recovered safely")]),
            ]),
        ])
        let executions = RuntimeBoundaryExecutionRecorder()
        let (service, sessionStore) = try self.makeAgentService()
        defer { sessionStore.cleanup() }
        let configuration = self.configuration(
            provider: provider,
            tools: ["see", "type", "click", "done"].map { name in
                AgentTool(
                    name: name,
                    description: name,
                    parameters: AgentToolParameters(properties: [:], required: []),
                    execute: { arguments in
                        await executions.record(name)
                        if name == "see", arguments["fail"]?.boolValue == true {
                            return try AnyAgentToolValue.fromJSON([
                                "error": "perception failed",
                                "success": false,
                            ])
                        }
                        if name == "see" {
                            return try AnyAgentToolValue.fromJSON(["error": NSNull(), "success": true])
                        }
                        return AnyAgentToolValue(string: "\(name)-ok")
                    })
            },
            eventHandler: nil)

        let outcome = if streaming {
            try await service.runStreamingLoop(
                configuration: configuration,
                maxSteps: 4,
                initialMessages: [.user("Recover from a failed observation safely.")])
        } else {
            try await service.runGenerationLoop(
                configuration: configuration,
                maxSteps: 4,
                initialMessages: [.user("Recover from a failed observation safely.")])
        }

        #expect(await executions.snapshot() == ["see", "type", "see", "see", "click", "done"])
        #expect(outcome.content == "Recovered safely")
        let failedStepResults = outcome.steps[1].toolResults
        #expect(failedStepResults.map(\.toolCallId) == ["failed-see", "blocked-type"])
        #expect(failedStepResults.map(\.isError) == [true, true])
        let blockedPayload = try #require(try failedStepResults[1].result.toJSON() as? [String: Any])
        #expect(blockedPayload["perception_required"] as? Bool == true)
        #expect(blockedPayload["skipped"] as? Bool == true)
    }

    @Test(arguments: [false, true])
    func `Semantic failures cannot terminate the agent`(_ streaming: Bool) async throws {
        let (service, sessionStore) = try self.makeAgentService()
        defer { sessionStore.cleanup() }
        let failedValue = try AnyAgentToolValue.fromJSON([
            "error": "semantic failure",
            "success": false,
        ])

        for terminalFails in [false, true] {
            let calls = terminalFails
                ? [AgentToolCall(id: "done-call", name: "done", arguments: [:])]
                : [
                    AgentToolCall(id: "probe-call", name: "probe", arguments: [:]),
                    AgentToolCall(id: "done-call", name: "done", arguments: [:]),
                ]
            let provider = RuntimeBoundaryProvider(text: "", toolCalls: calls)
            let configuration = self.configuration(
                provider: provider,
                tools: ["probe", "done"].map { name in
                    AgentTool(
                        name: name,
                        description: name,
                        parameters: AgentToolParameters(properties: [:], required: []),
                        execute: { _ in
                            if name == "probe" || terminalFails {
                                return failedValue
                            }
                            return AnyAgentToolValue(string: "done-ok")
                        })
                },
                eventHandler: nil)

            let outcome = if streaming {
                try await service.runStreamingLoop(
                    configuration: configuration,
                    maxSteps: 1,
                    initialMessages: [.user("Do not hide semantic failures.")])
            } else {
                try await service.runGenerationLoop(
                    configuration: configuration,
                    maxSteps: 1,
                    initialMessages: [.user("Do not hide semantic failures.")])
            }

            #expect(outcome.reachedStepLimit)
            #expect(outcome.content.isEmpty)
            #expect(service.turnBoundaryStopReason(from: outcome.steps[0].toolResults) == nil)
        }
    }

    @Test(arguments: [false, true])
    func `Terminal text after mutation continues until a fresh perception`(_ streaming: Bool) async throws {
        let provider = RuntimeBoundarySequenceProvider(steps: [
            .init(toolCalls: [
                AgentToolCall(id: "see-1", name: "see", arguments: [:]),
                AgentToolCall(id: "type-1", name: "type", arguments: [:]),
            ]),
            .init(text: "Ungrounded completion", toolCalls: [], finishReason: .stop),
            .init(toolCalls: [
                AgentToolCall(id: "see-2", name: "see", arguments: [:]),
            ]),
            .init(text: "Grounded completion", toolCalls: [], finishReason: .stop),
        ])
        let executions = RuntimeBoundaryExecutionRecorder()
        let (service, sessionStore) = try self.makeAgentService()
        defer { sessionStore.cleanup() }
        let configuration = self.configuration(
            provider: provider,
            tools: ["see", "type"].map { name in
                AgentTool(
                    name: name,
                    description: name,
                    parameters: AgentToolParameters(properties: [:], required: []),
                    execute: { _ in
                        await executions.record(name)
                        if name == "see" {
                            return try AnyAgentToolValue.fromJSON(["error": NSNull(), "success": true])
                        }
                        return AnyAgentToolValue(string: "type-ok")
                    })
            },
            eventHandler: nil)

        let outcome = if streaming {
            try await service.runStreamingLoop(
                configuration: configuration,
                maxSteps: 4,
                initialMessages: [.user("Ground completion after a fresh observation.")])
        } else {
            try await service.runGenerationLoop(
                configuration: configuration,
                maxSteps: 4,
                initialMessages: [.user("Ground completion after a fresh observation.")])
        }

        #expect(provider.requestCount == 4)
        #expect(await executions.snapshot() == ["see", "type", "see"])
        #expect(outcome.content == "Grounded completion")
        #expect(outcome.steps.map(\.text) == ["", "Ungrounded completion", "", "Grounded completion"])
        #expect(outcome.messages.contains { message in
            message.role == .user && message.content.contains { part in
                guard case let .text(text) = part else { return false }
                return text == PeekabooAgentService.freshPerceptionTerminalRejection
            }
        })
        #expect(!outcome.reachedStepLimit)
    }

    @Test(arguments: [false, true])
    func `Incomplete text-only see cannot authorize a terminal state claim`(_ streaming: Bool) async throws {
        let provider = RuntimeBoundarySequenceProvider(steps: [
            .init(toolCalls: [
                AgentToolCall(id: "see-1", name: "see", arguments: [:]),
                AgentToolCall(id: "type-1", name: "type", arguments: [:]),
            ]),
            .init(toolCalls: [
                AgentToolCall(
                    id: "see-2",
                    name: "see",
                    arguments: [
                        "app_target": AnyAgentToolValue(string: "PID:42"),
                        "incomplete": AnyAgentToolValue(bool: true),
                        "window_id": AnyAgentToolValue(int: 7),
                    ]),
            ]),
            .init(text: "The requested value is absent.", toolCalls: [], finishReason: .stop),
            .init(toolCalls: [
                AgentToolCall(id: "verify-1", name: "verify_state", arguments: [
                    "pid": AnyAgentToolValue(int: 42),
                    "window_id": AnyAgentToolValue(int: 7),
                ]),
            ]),
            .init(toolCalls: [
                AgentToolCall(id: "verify-2", name: "verify_state", arguments: [
                    "pid": AnyAgentToolValue(int: 42),
                    "window_id": AnyAgentToolValue(int: 7),
                ]),
            ]),
            .init(text: "The exact postcondition is verified.", toolCalls: [], finishReason: .stop),
        ])
        let executions = RuntimeBoundaryExecutionRecorder()
        let (service, sessionStore) = try self.makeAgentService()
        defer { sessionStore.cleanup() }
        let configuration = self.configuration(
            provider: provider,
            tools: ["see", "type", "verify_state"].map { name in
                AgentTool(
                    name: name,
                    description: name,
                    parameters: AgentToolParameters(properties: [:], required: []),
                    execute: { arguments in
                        await executions.record(name)
                        if name == "see", arguments["incomplete"]?.boolValue == true {
                            return AnyAgentToolValue(string: AgentToolMCPBridge.incompleteVisualEvidenceMarker)
                        }
                        if name == "see" {
                            return AnyAgentToolValue(string: "Complete observation")
                        }
                        if name == "verify_state" {
                            return AnyAgentToolValue(object: [
                                "content": AnyAgentToolValue(string: "Verification satisfied after 2 sample(s)."),
                                "verification_receipt": AnyAgentToolValue(object: [
                                    "status": AnyAgentToolValue(string: "satisfied"),
                                    "target": AnyAgentToolValue(object: [
                                        "pid": AnyAgentToolValue(int: 42),
                                        "window_id": AnyAgentToolValue(int: 7),
                                    ]),
                                    "predicates": AnyAgentToolValue(array: [
                                        AnyAgentToolValue(object: [
                                            "kind": AnyAgentToolValue(string: "element_value"),
                                            "selector": AnyAgentToolValue(object: [
                                                "identifier": AnyAgentToolValue(string: "target-field"),
                                            ]),
                                            "expected_value": AnyAgentToolValue(string: "complete"),
                                            "status": AnyAgentToolValue(string: "satisfied"),
                                        ]),
                                    ]),
                                ]),
                            ])
                        }
                        return AnyAgentToolValue(string: "type-ok")
                    })
            },
            eventHandler: nil)

        let outcome = if streaming {
            try await service.runStreamingLoop(
                configuration: configuration,
                maxSteps: 6,
                initialMessages: [.user("Type and verify an exact value.")])
        } else {
            try await service.runGenerationLoop(
                configuration: configuration,
                maxSteps: 6,
                initialMessages: [.user("Type and verify an exact value.")])
        }

        #expect(provider.requestCount == 6)
        #expect(await executions.snapshot() == ["see", "type", "see", "verify_state", "verify_state"])
        #expect(outcome.content == "The exact postcondition is verified.")
        #expect(outcome.steps.map(\.text) == [
            "", "", "The requested value is absent.", "", "", "The exact postcondition is verified.",
        ])
        #expect(outcome.messages.contains { message in
            message.role == .user && message.content.contains { part in
                guard case let .text(text) = part else { return false }
                return text.hasPrefix(PeekabooAgentService.completionEvidenceTerminalRejectionPrefix)
            }
        })
        #expect(!outcome.reachedStepLimit)
    }

    private func configuration(
        provider: any ModelProvider,
        tools: [AgentTool],
        eventHandler: EventHandler?) -> PeekabooAgentService.StreamingLoopConfiguration
    {
        PeekabooAgentService.StreamingLoopConfiguration(
            model: self.model,
            provider: provider,
            tools: tools,
            sessionId: "runtime-boundary-test",
            eventHandler: eventHandler,
            enhancementOptions: nil,
            executionPolicy: .unrestricted)
    }

    private func tool(named name: String, counter: RuntimeBoundaryCounter? = nil) -> AgentTool {
        AgentTool(
            name: name,
            description: name,
            parameters: AgentToolParameters(properties: [:], required: []),
            execute: { _ in
                await counter?.increment()
                return AnyAgentToolValue(string: "\(name)-ok")
            })
    }

    private func makeAgentService() throws -> (
        service: PeekabooAgentService,
        store: IsolatedAgentSessionStore)
    {
        let store = try IsolatedAgentSessionStore()
        let service = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: self.model,
            sessionManager: store.manager)
        return (service, store)
    }

    private static func decodeObject(_ value: String) -> [String: Any]? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

private enum RuntimeTerminalFixture: CaseIterable {
    case done
    case needInfo

    var call: AgentToolCall {
        switch self {
        case .done:
            AgentToolCall(
                id: "done-call",
                name: "done",
                arguments: ["message": AnyAgentToolValue(string: "Finished export")])
        case .needInfo:
            AgentToolCall(
                id: "need-info-call",
                name: "need_info",
                arguments: ["question": AnyAgentToolValue(string: "Which account?")])
        }
    }

    var reason: String {
        switch self {
        case .done: "Finished export"
        case .needInfo: "Need more information: Which account?"
        }
    }
}

private final class RuntimeBoundaryProvider: ModelProvider, @unchecked Sendable {
    let modelId = "runtime-boundary-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    private let text: String
    private let toolCalls: [AgentToolCall]
    private let emitsTerminalEvent: Bool

    init(
        text: String,
        toolCalls: [AgentToolCall],
        emitsTerminalEvent: Bool = true)
    {
        self.text = text
        self.toolCalls = toolCalls
        self.emitsTerminalEvent = emitsTerminalEvent
    }

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        ProviderResponse(
            text: self.text,
            finishReason: .toolCalls,
            toolCalls: self.toolCalls)
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        AsyncThrowingStream { continuation in
            if !self.text.isEmpty {
                continuation.yield(.text(self.text))
            }
            for toolCall in self.toolCalls {
                continuation.yield(.tool(toolCall))
            }
            if self.emitsTerminalEvent {
                continuation.yield(.done(finishReason: .toolCalls))
            }
            continuation.finish()
        }
    }
}

private final class RuntimeBoundarySequenceProvider: ModelProvider, @unchecked Sendable {
    struct Step {
        let text: String
        let toolCalls: [AgentToolCall]
        let finishReason: FinishReason

        init(
            text: String = "",
            toolCalls: [AgentToolCall],
            finishReason: FinishReason = .toolCalls)
        {
            self.text = text
            self.toolCalls = toolCalls
            self.finishReason = finishReason
        }
    }

    let modelId = "runtime-boundary-sequence-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    private let lock = NSLock()
    private let steps: [Step]
    private var nextIndex = 0
    private var continueBoundaryObservations: [Bool] = []
    private var observedContinueBoundaryReasons: [String?] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    var requestCount: Int {
        self.lock.withLock { self.nextIndex }
    }

    var requestsContainingContinueBoundary: [Bool] {
        self.lock.withLock { self.continueBoundaryObservations }
    }

    var continueBoundaryReasons: [String?] {
        self.lock.withLock { self.observedContinueBoundaryReasons }
    }

    func generateText(request: ProviderRequest) async throws -> ProviderResponse {
        let step = try self.nextStep(for: request)
        return ProviderResponse(
            text: step.text,
            finishReason: step.finishReason,
            toolCalls: step.toolCalls)
    }

    func streamText(request: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        let step = try self.nextStep(for: request)
        return AsyncThrowingStream { continuation in
            if !step.text.isEmpty {
                continuation.yield(.text(step.text))
            }
            for toolCall in step.toolCalls {
                continuation.yield(.tool(toolCall))
            }
            continuation.yield(.done(finishReason: step.finishReason))
            continuation.finish()
        }
    }

    private func nextStep(for request: ProviderRequest) throws -> Step {
        try self.lock.withLock {
            guard self.nextIndex < self.steps.count else {
                throw TachikomaError.apiError("Boundary test provider exhausted")
            }
            let reason = Self.continueBoundaryReason(request.messages)
            self.continueBoundaryObservations.append(reason != nil)
            self.observedContinueBoundaryReasons.append(reason)
            defer { self.nextIndex += 1 }
            return self.steps[self.nextIndex]
        }
    }

    private static func continueBoundaryReason(_ messages: [ModelMessage]) -> String? {
        for message in messages.reversed() {
            for part in message.content.reversed() {
                guard case let .toolResult(result) = part,
                      let json = try? result.result.toJSON(),
                      let payload = json as? [String: Any],
                      let boundary = payload["turn_boundary"] as? [String: Any],
                      boundary["continue_next_step"] as? Bool == true
                else { continue }
                return boundary["reason"] as? String
            }
        }
        return nil
    }
}

private actor RuntimeBoundaryExecutionRecorder {
    private var names: [String] = []

    func record(_ name: String) {
        self.names.append(name)
    }

    func snapshot() -> [String] {
        self.names
    }
}

private actor RuntimeBoundaryCounter {
    private var hasExecuted = false

    var isEmpty: Bool {
        !self.hasExecuted
    }

    func increment() {
        self.hasExecuted = true
    }
}

private actor RuntimeBoundaryEventRecorder {
    private var events: [AgentEvent] = []

    func record(_ event: AgentEvent) {
        self.events.append(event)
    }

    func snapshot() -> [AgentEvent] {
        self.events
    }
}

extension [AgentEvent] {
    var startedToolNames: [String] {
        self.compactMap { event in
            if case let .toolCallStarted(name, _) = event {
                name
            } else {
                nil
            }
        }
    }

    var completedTools: [(name: String, result: String)] {
        self.compactMap { event in
            if case let .toolCallCompleted(name, result) = event {
                (name, result)
            } else {
                nil
            }
        }
    }
}
