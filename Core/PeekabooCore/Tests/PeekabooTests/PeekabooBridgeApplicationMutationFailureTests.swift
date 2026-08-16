import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeApplicationMutationFailureTests {
    @Test
    @MainActor
    func `application handlers reject every returned non-success outcome before building success`() async throws {
        let applications = StubApplicationService()
        let server = Self.server(applications: applications)
        let identity = ApplicationProcessIdentity(processIdentifier: 123, processStartIdentity: 456)
        let expectedReceipt = DesktopActionTargetReceipt(
            processIdentifier: identity.processIdentifier,
            processStartIdentity: identity.processStartIdentity)
        let requests: [(request: PeekabooBridgeRequest, hasProcessTarget: Bool)] = [
            (.launchApplication(.init(identifier: "StubApp")), true),
            (.launchApplicationWithOptions(.init(applicationIdentifier: "StubApp", activates: true)), true),
            (.relaunchApplicationWithOptions(.init(
                targetIdentifier: "PID:123",
                expectedTargetIdentity: .init(processIdentifier: 123, processStartIdentity: 455),
                launchRequest: .init(applicationIdentifier: "StubApp", activates: true))), true),
            (.activateApplication(.init(identifier: "PID:123", expectedIdentity: identity)), true),
            (.quitApplication(.init(identifier: "PID:123", force: false, expectedIdentity: identity)), true),
            (.hideApplication(.init(identifier: "PID:123", expectedIdentity: identity)), true),
            (.hideOtherApplications(.init(identifier: "StubApp")), false),
            (.showAllApplications, false),
        ]

        for outcome in Self.nonSuccessOutcomes {
            applications.actionOutcome = outcome
            for entry in requests {
                do {
                    _ = try await Self.handleCurrent(entry.request, with: server)
                    Issue.record(
                        "Expected \(entry.request.operation.rawValue) to reject \(outcome.state.rawValue)")
                } catch let failure as DesktopActionFailure {
                    #expect(failure.outcome == outcome)
                    #expect(failure.targetReceipt == (entry.hasProcessTarget ? expectedReceipt : nil))
                } catch {
                    Issue.record(
                        "Expected DesktopActionFailure for \(entry.request.operation.rawValue), got \(error)")
                }
            }
        }
    }

    @Test
    @MainActor
    func `signed application client preserves provider failure outcome and process target`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-app-result-failure-\(UUID().uuidString).sock"
        let applications = StubApplicationService()
        let server = Self.server(applications: applications)
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let expectedReceipt = DesktopActionTargetReceipt(
            processIdentifier: 123,
            processStartIdentity: 456)

        for outcome in Self.nonSuccessOutcomes {
            applications.actionOutcome = outcome
            do {
                _ = try await client.launchApplication(identifier: "StubApp")
                Issue.record("Expected signed launch to reject \(outcome.state.rawValue)")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome == outcome.routed(to: .bridge))
                #expect(failure.targetReceipt == expectedReceipt)
            } catch {
                Issue.record("Expected signed DesktopActionFailure, got \(error)")
            }

            let bundle = try #require(await client.lastOperationReceiptBundle())
            try bundle.validate()
            let expectedSignedTarget: PeekabooBridgeOperationTargetReceipt? =
                outcome.dispatchState.mutationDispatched
                    ? .process(.init(
                        processIdentifier: expectedReceipt.processIdentifier,
                        processStartIdentity: expectedReceipt.processStartIdentity))
                    : nil
            #expect(bundle.receipt.payload.target == expectedSignedTarget)
            #expect(bundle.receipt.payload.outcome == outcome.routed(to: .bridge).projection)
        }

        await host.stop()
    }

    @MainActor
    private static func server(applications: any ApplicationServiceProtocol) -> PeekabooBridgeServer {
        PeekabooBridgeServer(
            services: StubServices(applications: applications),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in self.permissions })
    }

    @MainActor
    private static func handleCurrent(
        _ request: PeekabooBridgeRequest,
        with server: PeekabooBridgeServer) async throws -> PeekabooBridgeHandledResponse
    {
        try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
            try await server.handleAuthorized(request, peer: nil, permissions: self.permissions)
        }
    }

    private static let nonSuccessOutcomes: [DesktopActionOutcome] = [
        .refused(reason: .targetUnavailable),
        .partial(
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            unitCount: .one),
        .suspectedNoop(
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            unitCount: .one),
        .indeterminate(
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: .one),
    ]

    private static let permissions = PermissionsStatus(
        screenRecording: true,
        accessibility: true,
        postEvent: true)
    private static let clientIdentity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peekaboo.application-mutation-failure-tests",
        teamIdentifier: nil,
        processIdentifier: getpid(),
        hostname: nil)
}
