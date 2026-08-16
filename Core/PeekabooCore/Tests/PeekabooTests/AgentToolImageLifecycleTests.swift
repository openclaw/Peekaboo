import Foundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
@MainActor
struct AgentToolImageLifecycleTests {
    private let model = LanguageModel.anthropic(.opus47)

    @Test(arguments: [false, true])
    func `normal loop return discards its pending images`(_ streaming: Bool) async throws {
        let store = AgentToolMCPImageStore(maximumEntries: 8)
        let executionID = "normal-\(streaming)"
        let service = try PeekabooAgentService(services: PeekabooServices())
        let provider = ImageLifecycleProvider(mode: .success, store: store, executionID: executionID)
        let configuration = self.configuration(provider: provider)

        if streaming {
            _ = try await service.runStreamingLoop(
                configuration: configuration,
                maxSteps: 1,
                initialMessages: [.user("Finish normally")],
                imageContextID: executionID,
                imageStore: store)
        } else {
            _ = try await service.runGenerationLoop(
                configuration: configuration,
                maxSteps: 1,
                initialMessages: [.user("Finish normally")],
                imageContextID: executionID,
                imageStore: store)
        }

        #expect(provider.observedActiveExecution)
        await self.expectReleased(
            store: store,
            executionID: executionID,
            oldKeys: provider.pendingKeys,
            label: "normal-\(streaming)")
    }

    @Test
    func `streaming loop error discards its pending images`() async throws {
        let store = AgentToolMCPImageStore(maximumEntries: 8)
        let executionID = "error-execution"
        let service = try PeekabooAgentService(services: PeekabooServices())
        let provider = ImageLifecycleProvider(mode: .failure, store: store, executionID: executionID)
        let configuration = self.configuration(provider: provider)

        await #expect(throws: ImageLifecycleTestError.self) {
            _ = try await service.runStreamingLoop(
                configuration: configuration,
                maxSteps: 1,
                initialMessages: [.user("Fail")],
                imageContextID: executionID,
                imageStore: store)
        }

        #expect(provider.observedActiveExecution)
        await self.expectReleased(
            store: store,
            executionID: executionID,
            oldKeys: provider.pendingKeys,
            label: "error")
    }

    @Test
    func `streaming loop cancellation rejects delayed noncooperative image completion`() async throws {
        let store = AgentToolMCPImageStore(maximumEntries: 8)
        let executionID = "cancelled-execution"
        let service = try PeekabooAgentService(services: PeekabooServices())
        let provider = ImageLifecycleProvider(mode: .toolCall, store: store, executionID: executionID)
        let lateResult = DelayedImageStoreProbe()
        let lateKey = AgentToolMCPImageStore.Key(
            sessionID: "image-lifecycle-tests",
            executionID: executionID,
            stepIndex: 0,
            toolCallID: "late-result")
        let lateImage = ModelMessage.ContentPart.ImageContent(data: "late", mimeType: "image/png")
        let tool = AgentTool(
            name: provider.toolCall.name,
            description: "Cancellation probe",
            parameters: AgentToolParameters(properties: [:], required: []),
            execute: { _ in
                await lateResult.start(store: store, key: lateKey, image: lateImage)
                throw CancellationError()
            })
        let configuration = self.configuration(
            provider: provider,
            tools: [tool])
        let task = Task { @MainActor in
            try await service.runStreamingLoop(
                configuration: configuration,
                maxSteps: 1,
                initialMessages: [.user("Cancel")],
                imageContextID: executionID,
                imageStore: store)
        }

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await lateResult.releaseAndWait() == .rejected(.executionNotActive))
        #expect(provider.observedActiveExecution)
        await self.expectReleased(
            store: store,
            executionID: executionID,
            oldKeys: provider.pendingKeys,
            label: "cancelled")
    }

    private func configuration(
        provider: any ModelProvider,
        tools: [AgentTool] = [],
        eventHandler: EventHandler? = nil) -> PeekabooAgentService.StreamingLoopConfiguration
    {
        PeekabooAgentService.StreamingLoopConfiguration(
            model: self.model,
            provider: provider,
            tools: tools,
            sessionId: "image-lifecycle-tests",
            eventHandler: eventHandler,
            enhancementOptions: nil,
            executionPolicy: .unrestricted)
    }

    private func expectReleased(
        store: AgentToolMCPImageStore,
        executionID: String,
        oldKeys: [AgentToolMCPImageStore.Key],
        label: String) async
    {
        #expect(await !store.isActive(executionID: executionID))
        for key in oldKeys {
            #expect(await store.take(for: key).isEmpty)
        }
        let lateImage = ModelMessage.ContentPart.ImageContent(data: "late", mimeType: "image/png")
        #expect(await store.store([lateImage], for: oldKeys[0]) == .rejected(.executionNotActive))
        let replacement = AgentToolMCPImageStore.Key(
            sessionID: "image-lifecycle-tests",
            executionID: "replacement-\(label)",
            stepIndex: 0,
            toolCallID: "replacement")
        let image = ModelMessage.ContentPart.ImageContent(data: "replacement", mimeType: "image/png")
        #expect(await store.register(executionID: replacement.executionID))
        #expect(await store.store([image], for: replacement) == .admitted)
        #expect(await store.take(for: replacement) == [image])
        await store.close(executionID: replacement.executionID)
    }
}

private actor DelayedImageStoreProbe {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var task: Task<AgentToolMCPImageStore.Admission, Never>?

    func start(
        store: AgentToolMCPImageStore,
        key: AgentToolMCPImageStore.Key,
        image: ModelMessage.ContentPart.ImageContent)
    {
        self.task = Task {
            await self.waitForRelease()
            return await store.store([image], for: key)
        }
    }

    func releaseAndWait() async -> AgentToolMCPImageStore.Admission? {
        self.released = true
        self.continuation?.resume()
        self.continuation = nil
        return await self.task?.value
    }

    private func waitForRelease() async {
        guard !self.released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

private enum ImageLifecycleTestError: Error {
    case expected
}

private final class ImageLifecycleProvider: ModelProvider, @unchecked Sendable {
    enum Mode {
        case success
        case failure
        case toolCall
    }

    let modelId = "image-lifecycle-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()
    let toolCall = AgentToolCall(id: "cancel-probe", name: "probe", arguments: [:])
    let pendingKeys: [AgentToolMCPImageStore.Key]
    private let mode: Mode
    private let store: AgentToolMCPImageStore
    private let executionID: String
    private let lock = NSLock()
    private var observedActive = false

    init(mode: Mode, store: AgentToolMCPImageStore, executionID: String) {
        self.mode = mode
        self.store = store
        self.executionID = executionID
        self.pendingKeys = (0..<8).map { index in
            AgentToolMCPImageStore.Key(
                sessionID: "image-lifecycle-tests",
                executionID: executionID,
                stepIndex: 0,
                toolCallID: "pending-\(index)")
        }
    }

    var observedActiveExecution: Bool {
        self.lock.withLock { self.observedActive }
    }

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        await self.storePendingImages()
        return switch self.mode {
        case .success:
            ProviderResponse(text: "Complete", finishReason: .stop)
        case .failure:
            throw ImageLifecycleTestError.expected
        case .toolCall:
            ProviderResponse(text: "", finishReason: .toolCalls, toolCalls: [self.toolCall])
        }
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        await self.storePendingImages()
        return AsyncThrowingStream { continuation in
            switch self.mode {
            case .success:
                continuation.yield(.text("Complete"))
                continuation.yield(.done(finishReason: .stop))
                continuation.finish()
            case .failure:
                continuation.finish(throwing: ImageLifecycleTestError.expected)
            case .toolCall:
                continuation.yield(.tool(self.toolCall))
                continuation.yield(.done(finishReason: .toolCalls))
                continuation.finish()
            }
        }
    }

    private func storePendingImages() async {
        let isActive = await self.store.isActive(executionID: self.executionID)
        self.lock.withLock { self.observedActive = isActive }
        let image = ModelMessage.ContentPart.ImageContent(data: "pending", mimeType: "image/png")
        for key in self.pendingKeys {
            let admission = await self.store.store([image], for: key)
            if admission != .admitted {
                Issue.record("Expected active loop image admission, got \(admission)")
            }
        }
    }
}
