import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeSetValueFailureTests {
    @Test
    func `signed client preserves post-dispatch readback failure and target receipt`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-set-value-failure-\(UUID().uuidString).sock"
        let services = await MainActor.run { StubServices() }
        let processGeneration = try #require(SystemIdentityResolver.processStartIdentity(getpid()))
        let targetReceipt = DesktopActionTargetReceipt(
            processIdentifier: getpid(),
            processStartIdentity: processGeneration)
        await MainActor.run {
            services.automationStub.actionOutcome = .dispatchedUnverified(
                delivery: .init(mechanism: .accessibilityValue, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one)
            services.automationStub.uiAutomationOutcomeTargetIdentity = try? DesktopTargetIdentity(
                processIdentity: .init(
                    processIdentifier: getpid(),
                    processStartIdentity: processGeneration))
            services.automationStub.elementActionError = DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .accessibilityValue, mode: .background),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "The submitted value could not be read back.",
                hint: "Observe the exact target before retrying.")
                .attributed(to: targetReceipt)
        }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: services,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [])
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.set-value-failure-tests",
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: nil))
        let remote = await MainActor.run { RemoteElementActionUIAutomationService(client: client) }
        do {
            _ = try await remote.setValueWithOutcome(
                target: "T1",
                value: .string("hello"),
                snapshotId: "S1")
            Issue.record("Expected typed set-value failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.message == "The submitted value could not be read back.")
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == .init(mechanism: .accessibilityValue, mode: .background))
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.projection.requiresFreshObservation)
            #expect(failure.targetReceipt == targetReceipt)
            #expect(failure.hint?.contains("Observe the exact target") == true)
        }
    }
}
