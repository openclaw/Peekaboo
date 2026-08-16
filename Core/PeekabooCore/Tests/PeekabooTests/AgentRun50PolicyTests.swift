import Foundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
@MainActor
struct AgentRun50PolicyTests {
    private let model = LanguageModel.anthropic(.opus47)

    @Test
    func `Agent preflight validates provider arguments before execution policy`() throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        let tool = AgentTool(
            name: "press",
            description: "validation ordering probe",
            parameters: AgentToolParameters(
                properties: [
                    "key": AgentToolParameterProperty(name: "key", type: .string, description: "Primary key"),
                    "foreground": AgentToolParameterProperty(
                        name: "foreground",
                        type: .boolean,
                        description: "Foreground consent"),
                ],
                required: ["key"]),
            execute: { _ in
                Issue.record("Preflight probe must never execute")
                return AnyAgentToolValue(string: "unexpected")
            })
        let context = PeekabooAgentService.ToolHandlingContext(
            model: self.model,
            tools: [tool],
            eventHandler: nil,
            sessionId: "run50-agent-validation",
            executionPolicy: .backgroundOnly)

        let invalid = try #require(service.makeToolPreflightResult(
            for: AgentToolCall(
                id: "invalid",
                name: "press",
                arguments: [
                    "key": AnyAgentToolValue(int: 7),
                    "foreground": AnyAgentToolValue(bool: true),
                ]),
            context: context))
        #expect(invalid.isError)
        #expect(invalid.failure?.metadata?.objectValue?["error_code"]?.stringValue == "VALIDATION_ERROR")
        #expect(invalid.failure?.metadata?.objectValue?["refusal_reason"]?.stringValue == "invalid_request")

        let validButForbidden = try #require(service.makeToolPreflightResult(
            for: AgentToolCall(
                id: "forbidden",
                name: "press",
                arguments: [
                    "key": AnyAgentToolValue(string: "c"),
                    "foreground": AnyAgentToolValue(bool: true),
                ]),
            context: context))
        #expect(validButForbidden.isError)
        #expect(validButForbidden.failure?.metadata?.objectValue?["error_code"]?.stringValue ==
            MCPToolExecutionPolicy.refusalErrorCode)
        #expect(validButForbidden.failure?.metadata?.objectValue?["refusal_reason"]?.stringValue ==
            "foreground_consent_required")
    }

    @Test
    func `default Agent prompt never recommends impossible foreground calls`() {
        let background = AgentSystemPrompt.generate(for: self.model)
        let foreground = AgentSystemPrompt.generate(for: self.model, executionPolicy: .foregroundAllowed)
        let unrestricted = AgentSystemPrompt.generate(for: self.model, executionPolicy: .unrestricted)

        #expect(background.contains("immutable background-only authority"))
        #expect(background.contains("exact targeted direct-text paste"))
        #expect(!background.contains(#""foreground": true"#))
        #expect(!background.contains(#""action": "focus""#))
        #expect(!background.contains(#""action": "switch""#))
        #expect(foreground.contains(#""foreground": true"#))
        #expect(foreground.contains("explicit foreground UI authority"))
        #expect(unrestricted.contains(#""foreground": true"#))
        #expect(unrestricted.contains("unrestricted tool authority"))
        #expect(unrestricted.contains("foreground/global UI and Shell"))
        #expect(!unrestricted.contains("immutable background-only authority"))
        #expect(!unrestricted.contains("but not Shell authority"))
    }

    @Test
    func `background resume replaces a stored foreground prompt`() throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        let foregroundPrompt = AgentSystemPrompt.generate(
            for: self.model,
            executionPolicy: .foregroundAllowed)
        let session = AgentSession(
            id: "run50-foreground-session",
            modelName: "fixture",
            toolExecutionPolicy: .foregroundAllowed,
            messages: [.system(foregroundPrompt), .user("saved task")],
            metadata: SessionMetadata(),
            createdAt: Date(),
            updatedAt: Date())

        let resumed = service.makeContinuationContext(
            from: session,
            userMessage: nil,
            model: self.model,
            toolExecutionPolicy: .backgroundOnly)
        let prompt = resumed.messages
            .first(where: { $0.role == .system })?
            .content
            .compactMap { part -> String? in
                guard case let .text(text) = part else { return nil }
                return text
            }
            .joined(separator: "\n")

        #expect(prompt?.contains("immutable background-only authority") == true)
        #expect(prompt?.contains(#""foreground": true"#) == false)
        #expect(resumed.storedToolExecutionPolicy == .foregroundAllowed)
        #expect(resumed.toolExecutionPolicy == .backgroundOnly)
    }

    @Test
    func `Agent turn planner treats only background menu list and safe launch as reads`() {
        let backgroundLaunch = AgentTurnBoundary()
        #expect(backgroundLaunch.record(
            toolName: "app",
            arguments: [
                "action": AnyAgentToolValue(string: "launch"),
                "name": AnyAgentToolValue(string: "TextEdit"),
            ]) == .continueTurn)

        let foregroundLaunch = AgentTurnBoundary()
        #expect(foregroundLaunch.record(
            toolName: "app",
            arguments: [
                "action": AnyAgentToolValue(string: "launch"),
                "name": AnyAgentToolValue(string: "TextEdit"),
                "foreground": AnyAgentToolValue(bool: true),
            ]) == .continueNextStep(reason: "Stopped after app; call `see` before the next UI action."))

        let backgroundMenuList = AgentTurnBoundary()
        #expect(backgroundMenuList.record(
            toolName: "menu",
            arguments: [
                "action": AnyAgentToolValue(string: "list"),
                "app": AnyAgentToolValue(string: "TextEdit"),
            ]) == .continueTurn)

        let foregroundMenuList = AgentTurnBoundary()
        #expect(foregroundMenuList.record(
            toolName: "menu",
            arguments: [
                "action": AnyAgentToolValue(string: "list"),
                "app": AnyAgentToolValue(string: "TextEdit"),
                "foreground": AnyAgentToolValue(bool: true),
            ]) == .continueNextStep(reason: "Stopped after menu; call `see` before the next UI action."))
    }
}
