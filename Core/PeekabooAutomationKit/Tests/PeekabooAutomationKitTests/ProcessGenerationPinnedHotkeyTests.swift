import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
@MainActor
struct ProcessGenerationPinnedHotkeyTests {
    @Test
    func `Changed process generation rejects targeted type before delivery`() async throws {
        let service = self.makeService(
            currentGeneration: { 90 },
            eventPoster: { _, _ in Issue.record("Type validation must not post hotkey events") })

        await #expect(throws: PeekabooError.self) {
            _ = try await service.typeActions(
                [],
                cadence: .fixed(milliseconds: 0),
                snapshotId: nil,
                expectedProcessIdentity: self.identity(generation: 89))
        }
    }

    @Test
    func `Unchanged process generation completes targeted hotkey`() async throws {
        var postedEvents: [CGEventType] = []
        let identity = self.identity(generation: 91)
        let service = self.makeService(
            currentGeneration: { 91 },
            eventPoster: { event, _ in postedEvents.append(event.type) })

        try await service.hotkey(
            keys: "cmd,shift,l",
            holdDuration: 0,
            expectedProcessIdentity: identity)

        #expect(postedEvents == [
            .flagsChanged,
            .flagsChanged,
            .keyDown,
            .keyUp,
            .flagsChanged,
            .flagsChanged,
        ])
    }

    @Test
    func `Changed process generation before dispatch emits nothing`() async throws {
        var postedEventCount = 0
        let service = self.makeService(
            currentGeneration: { 93 },
            eventPoster: { _, _ in postedEventCount += 1 })

        await #expect(throws: PeekabooError.self) {
            try await service.hotkey(
                keys: "cmd,shift,l",
                holdDuration: 0,
                expectedProcessIdentity: self.identity(generation: 92))
        }
        #expect(postedEventCount == 0)
    }

    @Test
    func `Process generation drift after dispatch is retry unsafe`() async throws {
        let generation = LockedProcessGeneration(94)
        var postedEventCount = 0
        let service = self.makeService(
            currentGeneration: { generation.value },
            eventPoster: { _, _ in
                postedEventCount += 1
                if postedEventCount == 6 {
                    generation.value = 95
                }
            })

        do {
            try await service.hotkey(
                keys: "cmd,shift,l",
                holdDuration: 0,
                expectedProcessIdentity: self.identity(generation: 94))
            Issue.record("Expected process-generation drift to fail closed")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.operation == .hotkey)
            #expect(error.emittedUnitCount == 6)
            #expect(error.operationMayHaveCompleted)
            #expect(!error.retrySafe)
            #expect(error.causeDescription?.contains("process generation") == true)
        }

        #expect(postedEventCount == 6)
    }

    private func makeService(
        currentGeneration: @escaping @Sendable () -> UInt64?,
        eventPoster: @escaping @MainActor @Sendable (CGEvent, pid_t) -> Void) -> UIAutomationService
    {
        UIAutomationService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            actionInputDriver: ActionInputDriver(),
            automationElementResolver: AutomationElementResolver(),
            hotkeyServiceFactory: { context in
                HotkeyService(
                    inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
                    postEventAccessEvaluator: { true },
                    eventPoster: eventPoster,
                    processStartIdentityProvider: context.processStartIdentityProvider,
                    desktopOperationExecutor: context.desktopOperationExecutor,
                    operationFinalizer: context.operationFinalizer)
            },
            processStartIdentityProvider: { _ in currentGeneration() })
    }

    private func identity(generation: UInt64) -> ApplicationProcessIdentity {
        ApplicationProcessIdentity(
            processIdentifier: getpid(),
            processStartIdentity: generation)
    }
}

private final class LockedProcessGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: UInt64?

    init(_ value: UInt64?) {
        self.storedValue = value
    }

    var value: UInt64? {
        get { self.lock.withLock { self.storedValue } }
        set { self.lock.withLock { self.storedValue = newValue } }
    }
}
