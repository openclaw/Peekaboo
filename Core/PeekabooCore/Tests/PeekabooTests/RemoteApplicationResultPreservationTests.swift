import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation
import Testing
@testable import PeekabooCore

struct RemoteApplicationResultPreservationTests {
    @Test
    @MainActor
    func `signed hide failure preserves selected process receipt`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-app-hide-failure-\(UUID().uuidString).sock"
        let applications = StubApplicationService()
        let identity = ApplicationProcessIdentity(processIdentifier: 123, processStartIdentity: 456)
        applications.targetedHideError = DesktopActionFailure.indeterminate(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "Hide completion is ambiguous")
        let server = PeekabooBridgeServer(
            services: StubServices(applications: applications),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)

        do {
            _ = try await client.hideApplicationTargetedResult(request: .init(
                identifier: "PID:123",
                expectedIdentity: identity))
            Issue.record("Expected signed hide failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.targetReceipt == .init(
                processIdentifier: identity.processIdentifier,
                processStartIdentity: identity.processStartIdentity))
        }

        await host.stop()
    }

    @Test
    @MainActor
    func `signed hide generation drift stays a target-attributed pre-dispatch refusal`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-app-hide-drift-\(UUID().uuidString).sock"
        let applications = StubApplicationService()
        let identity = ApplicationProcessIdentity(processIdentifier: 123, processStartIdentity: 456)
        applications.targetedHideError = DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Application process generation changed before hide dispatch.",
            hint: "Refresh the application inventory before retrying.")
            .attributed(to: .init(
                processIdentifier: identity.processIdentifier,
                processStartIdentity: identity.processStartIdentity))
        let server = PeekabooBridgeServer(
            services: StubServices(applications: applications),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)

        do {
            _ = try await client.hideApplicationTargetedResult(request: .init(
                identifier: "PID:123",
                expectedIdentity: identity))
            Issue.record("Expected signed hide generation refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.targetReceipt == .init(
                processIdentifier: identity.processIdentifier,
                processStartIdentity: identity.processStartIdentity))
        }

        await host.stop()
    }

    @Test
    @MainActor
    func `signed single quit rejects false payload with confirmed outcome`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-app-quit-contradiction-\(UUID().uuidString).sock"
        let applications = StubApplicationService()
        let identity = ApplicationProcessIdentity(processIdentifier: 123, processStartIdentity: 456)
        applications.quitResultPayload = false
        applications.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: .one)
        let server = PeekabooBridgeServer(
            services: StubServices(applications: applications),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)

        do {
            _ = try await client.quitApplicationResult(
                request: .init(identifier: "PID:123", expectedIdentity: identity),
                supportsPinnedQuit: true)
            Issue.record("Expected signed quit contradiction failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.delivery == .init(mechanism: .nativeFramework, mode: .background))
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.targetReceipt == .init(
                processIdentifier: identity.processIdentifier,
                processStartIdentity: identity.processStartIdentity))
        }

        await host.stop()
    }

    @Test
    @MainActor
    func `signed application refusal stays an error across every response family`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-app-refusal-results-\(UUID().uuidString).sock"
        let applications = RefusingApplicationService()
        let refusal = DesktopActionOutcome.refused(reason: .targetUnavailable)
        applications.actionOutcome = refusal
        let server = PeekabooBridgeServer(
            services: StubServices(applications: applications),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            daemonControl: StubDaemonControl())
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let identity = ApplicationProcessIdentity(processIdentifier: 123, processStartIdentity: 456)

        await Self.expectSignedRefusal(refusal, operationName: "launch") {
            _ = try await client.launchApplication(identifier: "StubApp")
        }
        await Self.expectSignedRefusal(refusal, operationName: "safe background launch") {
            _ = try await client.launchApplicationResult(request: .init(applicationIdentifier: "StubApp"))
        }
        await Self.expectSignedRefusal(refusal, operationName: "relaunch") {
            _ = try await client.relaunchApplicationResult(request: .init(
                targetIdentifier: "PID:123",
                expectedTargetIdentity: .init(processIdentifier: 123, processStartIdentity: 455),
                launchRequest: .init(applicationIdentifier: "StubApp", activates: true)))
        }
        await Self.expectSignedRefusal(refusal, operationName: "activate") {
            _ = try await client.activateApplicationTargetedResult(request: .init(
                identifier: "PID:123",
                expectedIdentity: identity))
        }
        await Self.expectSignedRefusal(refusal, operationName: "quit") {
            _ = try await client.quitApplicationResult(
                request: .init(identifier: "PID:123", expectedIdentity: identity),
                supportsPinnedQuit: true)
        }
        await Self.expectSignedRefusal(refusal, operationName: "hide") {
            _ = try await client.hideApplicationTargetedResult(request: .init(
                identifier: "PID:123",
                expectedIdentity: identity))
        }
        await Self.expectSignedRefusal(refusal, operationName: "hide others") {
            _ = try await client.hideOtherApplicationsResult(identifier: "StubApp")
        }
        await Self.expectSignedRefusal(refusal, operationName: "show all") {
            _ = try await client.showAllApplicationsResult()
        }

        await host.stop()
    }

    @Test
    @MainActor
    func `current remote preserves exact application targets and global lifecycle outcomes`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-app-targeted-results-\(UUID().uuidString).sock"
        let applications = await MainActor.run { StubApplicationService() }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(applications: applications),
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
        _ = try await client.handshake(client: Self.clientIdentity)
        let remote: any ApplicationServiceProtocol = await MainActor.run {
            RemoteApplicationService(
                client: client,
                supportsPinnedActivation: true,
                supportsPinnedHide: true)
        }
        let identity = ApplicationProcessIdentity(processIdentifier: 123, processStartIdentity: 456)
        let target = try DesktopTargetIdentity(processIdentity: identity)

        await MainActor.run {
            applications.actionOutcome = .confirmedChange(
                delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                unitCount: .one)
        }
        let activation = try await remote.activateApplicationTargetedResult(request: .init(
            identifier: "PID:123",
            expectedIdentity: identity))
        #expect(activation.targetIdentity == target)
        #expect(activation.outcome?.route == .bridge)
        #expect(activation.outcome?.state == .confirmedChange)

        let backgroundOutcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        await MainActor.run { applications.actionOutcome = backgroundOutcome }
        let hideRequest = try ApplicationHideRequest(identifier: "PID:123", expectedIdentity: identity)
        let hide = try await remote.hideApplicationTargetedResult(request: hideRequest)
        let hideOthers = try await remote.hideOtherApplicationsResult(identifier: "StubApp")
        let showAll = try await remote.showAllApplicationsResult()

        #expect(hide.targetIdentity == target)
        #expect(hide.outcome == backgroundOutcome.routed(to: .bridge))
        #expect(hideOthers.outcome == backgroundOutcome.routed(to: .bridge))
        #expect(showAll.outcome == backgroundOutcome.routed(to: .bridge))
        #expect(applications.targetedActivationResultCount == 1)
        #expect(applications.targetedHideResultCount == 1)
        #expect(applications.targetedHideRequests == [hideRequest])
        await host.stop()
    }

    @Test
    @MainActor
    func `signed safe background launch accepts only confirmed no-change`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-safe-app-check-\(UUID().uuidString).sock"
        let applications = SafeBackgroundResultApplicationService()
        let server = PeekabooBridgeServer(
            services: StubServices(applications: applications),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let request = ApplicationLaunchRequest(applicationIdentifier: "StubApp")

        applications.actionOutcome = .confirmedNoChange()
        let noChange = try await client.launchApplicationResult(request: request)
        #expect(noChange.outcome == nil)
        var bundle = try #require(await client.lastOperationReceiptBundle())
        try bundle.validate()
        #expect(bundle.receipt.payload.outcome == nil)

        let dispatched = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        applications.actionOutcome = dispatched
        do {
            _ = try await client.launchApplicationResult(request: request)
            Issue.record("Expected dispatching safe background provider result to fail")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome == dispatched.routed(to: .bridge))
        }
        bundle = try #require(await client.lastOperationReceiptBundle())
        try bundle.validate()
        #expect(bundle.receipt.payload.outcome == dispatched.routed(to: .bridge).projection)

        applications.actionOutcome = nil
        do {
            _ = try await client.launchApplicationResult(request: request)
            Issue.record("Expected missing safe background provider result to fail")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.route == .bridge)
        }
        bundle = try #require(await client.lastOperationReceiptBundle())
        try bundle.validate()
        #expect(bundle.receipt.payload.outcome?.state == .indeterminate)
        await host.stop()
    }

    @Test
    @MainActor
    func `legacy remote lifecycle results remain explicitly receiptless`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-app-legacy-results-\(UUID().uuidString).sock"
        let applications = await MainActor.run { StubApplicationService() }
        let legacyVersion = PeekabooBridgeConstants.exactForcedDialogDismissExecutionVersion
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(applications: applications),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                supportedVersions: legacyVersion...legacyVersion)
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity, protocolVersion: legacyVersion)
        let remote: any ApplicationServiceProtocol = await MainActor.run {
            RemoteApplicationService(client: client)
        }

        let foregroundOutcome = DesktopActionOutcome.confirmedChange(
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            unitCount: .one)
        applications.actionOutcome = foregroundOutcome
        let activation = try await remote.activateApplicationTargetedResult(request: .init(identifier: "StubApp"))
        let backgroundOutcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        applications.actionOutcome = backgroundOutcome
        let hide = try await remote.hideApplicationTargetedResult(identifier: "StubApp")
        let hideOthers = try await remote.hideOtherApplicationsResult(identifier: "StubApp")
        let showAll = try await remote.showAllApplicationsResult()

        #expect(activation.targetIdentity == nil)
        #expect(hide.targetIdentity == nil)
        #expect(activation.outcome == foregroundOutcome.routed(to: .bridge))
        #expect(hide.outcome == backgroundOutcome.routed(to: .bridge))
        #expect(hideOthers.outcome == nil)
        #expect(showAll.outcome == nil)
        #expect(applications.hideResultCount == 1)
        #expect(applications.targetedHideResultCount == 0)

        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await remote.hideApplicationTargetedResult(request: .init(
                identifier: "PID:123",
                expectedIdentity: .init(processIdentifier: 123, processStartIdentity: 456)))
        }
        #expect(applications.hideResultCount == 1)
        await host.stop()
    }

    @Test
    @MainActor
    func `protocol 1 28 hide does not require process-generation metadata`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-app-legacy-hide-\(UUID().uuidString).sock"
        let applications = LegacyGenerationlessHideApplicationService()
        let legacyVersion = PeekabooBridgeConstants.exactForcedDialogDismissExecutionVersion
        let server = PeekabooBridgeServer(
            services: StubServices(applications: applications),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            supportedVersions: legacyVersion...legacyVersion)
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity, protocolVersion: legacyVersion)
        let result = try await client.hideApplicationTargetedResult(identifier: "LegacyApp")

        #expect(result.outcome == applications.actionOutcome?.routed(to: .bridge))
        #expect(result.targetIdentity == nil)
        #expect(applications.hideResultCount == 1)
        await host.stop()
    }

    private static let clientIdentity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peekaboo.remote-application-result-tests",
        teamIdentifier: nil,
        processIdentifier: getpid(),
        hostname: nil)

    private static func expectSignedRefusal(
        _ expected: DesktopActionOutcome,
        operationName: String,
        operation: () async throws -> Void) async
    {
        do {
            try await operation()
            Issue.record("Expected signed \(operationName) refusal")
        } catch let failure as DesktopActionFailure {
            #expect(
                failure.outcome == expected.routed(to: .bridge),
                "Wrong refusal for \(operationName)")
            #expect(failure.outcome.dispatchState == .none)
        } catch {
            Issue.record("Expected DesktopActionFailure for \(operationName), got \(error)")
        }
    }
}

@MainActor
private final class LegacyGenerationlessHideApplicationService: StubApplicationService {
    override func findApplication(identifier _: String) async throws -> ServiceApplicationInfo {
        throw PeekabooError.appNotFound("LegacyApp has no process-generation metadata")
    }
}

@MainActor
private final class RefusingApplicationService: StubApplicationService {
    override var supportsSafeBackgroundApplicationLaunchNoOp: Bool {
        true
    }
}

@MainActor
private final class SafeBackgroundResultApplicationService: StubApplicationService {
    override var supportsSafeBackgroundApplicationLaunchNoOp: Bool {
        true
    }

    override func launchApplicationActionResult(
        request: ApplicationLaunchRequest) async throws -> DesktopActionResult<ServiceApplicationInfo>
    {
        let result = try await super.launchApplicationActionResult(request: request)
        guard let selector = request.applicationIdentifier ?? request.applicationBundleIdentifier else {
            return result
        }
        return DesktopActionResult(
            payload: result.payload.withUniqueTestSelectorProof(for: selector),
            outcome: result.outcome)
    }
}
