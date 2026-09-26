import ApplicationServices
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct TypeServiceAXFailureReceiptTests {
    enum Leaf: CaseIterable, Sendable {
        case text, space, clear

        var action: TypeAction {
            switch self {
            case .text: .text("x")
            case .space: .key(.space)
            case .clear: .clear
            }
        }

        var recordedCall: String {
            switch self {
            case .text: "text:x"
            case .space: "key:space"
            case .clear: "clear"
            }
        }
    }

    @Test(arguments: Leaf.allCases, [AXError.apiDisabled, .invalidUIElement])
    func `first AX leaf refusal remains retry safe`(leaf: Leaf, nativeError: AXError) async throws {
        let fixture = Fixture(nativeResults: [nativeError])

        do {
            try await fixture.run([leaf.action, .text("never")])
            Issue.record("Expected a pre-dispatch AX refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.projection.retrySafe)
            #expect(!failure.outcome.projection.mutationDispatched)
            #expect(failure.outcome.refusalReason ==
                (nativeError == .apiDisabled ? .permissionDenied : .targetUnavailable))
        } catch {
            Issue.record("Expected the canonical AX refusal, got \(error)")
        }

        #expect(fixture.calls == [leaf.recordedCall])
        #expect(fixture.keyTapCount == 0)
    }

    @Test(arguments: Leaf.allCases)
    func `uncertain AX leaf preserves only the known accepted prefix`(leaf: Leaf) async throws {
        let fixture = Fixture(nativeResults: [.success, .cannotComplete])

        do {
            try await fixture.run([.text("p"), leaf.action, .text("never")])
            Issue.record("Expected an uncertain AX leaf to stop the request")
        } catch let failure as InputDeliveryIndeterminateError {
            #expect(failure.operation == .type)
            #expect(failure.emittedUnitCount == 1)
            #expect(failure.delivery == Fixture.accessibilityDelivery)
            #expect(!failure.retrySafe)
            #expect(failure.operationMayHaveCompleted)
        } catch {
            Issue.record("Expected an indeterminate AX receipt, got \(error)")
        }

        #expect(fixture.calls == ["text:p", leaf.recordedCall])
        #expect(fixture.keyTapCount == 0)
    }

    @Test(arguments: Leaf.allCases, [AXError.apiDisabled, .invalidUIElement])
    func `AX refusal after an accepted prefix stays retry unsafe`(leaf: Leaf, nativeError: AXError) async throws {
        let fixture = Fixture(nativeResults: [.success, nativeError])

        do {
            try await fixture.run([.text("p"), leaf.action, .text("never")])
            Issue.record("Expected the accepted prefix to prevent a retry-safe refusal")
        } catch let failure as InputDeliveryIndeterminateError {
            #expect(failure.operation == .type)
            #expect(failure.emittedUnitCount == 1)
            #expect(failure.delivery == Fixture.accessibilityDelivery)
            #expect(!failure.retrySafe)
            #expect(failure.operationMayHaveCompleted)
        } catch {
            Issue.record("Expected an indeterminate prefix receipt, got \(error)")
        }

        #expect(fixture.calls == ["text:p", leaf.recordedCall])
        #expect(fixture.keyTapCount == 0)
    }

    @Test(arguments: Leaf.allCases)
    func `continuation receipt does not double count the accepted prefix`(leaf: Leaf) async throws {
        let fixture = Fixture(nativeResults: [.success])

        do {
            try await fixture.run(
                [.text("p"), leaf.action],
                continuationValidator: {
                    fixture.continuationChecks += 1
                    throw InputDeliveryIndeterminateError(
                        operation: .type,
                        emittedUnitCount: 1,
                        causeDescription: "Continuation receiver changed",
                        delivery: Fixture.accessibilityDelivery)
                })
            Issue.record("Expected continuation validation to stop the remaining leaf")
        } catch let failure as InputDeliveryIndeterminateError {
            #expect(failure.operation == .type)
            #expect(failure.emittedUnitCount == 1)
            #expect(failure.delivery == Fixture.accessibilityDelivery)
            #expect(failure.causeDescription == "Continuation receiver changed")
            #expect(!failure.retrySafe)
        } catch {
            Issue.record("Expected the original continuation receipt, got \(error)")
        }

        #expect(fixture.continuationChecks == 1)
        #expect(fixture.calls == ["text:p"])
        #expect(fixture.keyTapCount == 0)
    }

    @MainActor
    private final class Fixture {
        static let processIdentifier: pid_t = 4242
        static let accessibilityDelivery = DesktopActionOutcome.Delivery(
            mechanism: .accessibilityValue,
            mode: .background)

        var calls: [String] = []
        var keyTapCount = 0
        var continuationChecks = 0
        private var nativeResults: [AXError]

        init(nativeResults: [AXError]) {
            self.nativeResults = nativeResults
        }

        func run(
            _ actions: [TypeAction],
            continuationValidator: (@MainActor @Sendable () async throws -> Void)? = nil) async throws
        {
            let service = TypeService(
                snapshotManager: InMemorySnapshotManager(),
                randomSource: SystemTypingCadenceRandomSource(),
                focusedElementSecurityProbe: { _ in false },
                targetedCharacterTyper: { character, processIdentifier, _ in
                    try self.applyNativeResult("text:\(character)", processIdentifier: processIdentifier)
                    return .dispatched(delivery: Self.accessibilityDelivery, keyPressCount: 0)
                },
                targetedSpecialKeyTyper: { key, processIdentifier, _ in
                    #expect(key == .space)
                    try self.applyNativeResult("key:\(key.rawValue)", processIdentifier: processIdentifier)
                    return .dispatched(delivery: Self.accessibilityDelivery, keyPressCount: 0)
                },
                targetedKeyTapper: { _, _, _ in
                    self.keyTapCount += 1
                    Issue.record("AX failure must not fall back to keyboard input")
                    throw FixtureError.unexpectedKeyboardFallback
                },
                targetedTextReplacer: { text, processIdentifier, _, _, _ in
                    #expect(text.isEmpty)
                    try self.applyNativeResult("clear", processIdentifier: processIdentifier)
                    return .accessibilityValue
                })

            _ = try await service.typeActionsTrackingSecureInput(
                actions,
                cadence: .fixed(milliseconds: 0),
                snapshotId: nil,
                targetProcessIdentifier: Self.processIdentifier,
                continuationValidator: continuationValidator)
        }

        private func applyNativeResult(_ call: String, processIdentifier: pid_t) throws {
            #expect(processIdentifier == Self.processIdentifier)
            self.calls.append(call)
            guard !self.nativeResults.isEmpty else {
                Issue.record("Unexpected additional AX mutation attempt")
                throw FixtureError.unexpectedMutation
            }
            let accepted = try BackgroundInputDriver.textMutationAccepted(self.nativeResults.removeFirst())
            guard accepted else {
                Issue.record("The fixture must produce an accepted AX write or a native failure")
                throw FixtureError.unexpectedUnsupportedMutation
            }
        }
    }

    private enum FixtureError: Error {
        case unexpectedMutation
        case unexpectedUnsupportedMutation
        case unexpectedKeyboardFallback
    }
}
