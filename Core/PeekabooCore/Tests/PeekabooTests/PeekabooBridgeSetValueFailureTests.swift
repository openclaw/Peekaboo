import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeSetValueFailureTests {
    @Test
    @MainActor
    func `signed snapshot refusal cancels the Bridge mutation barrier without watermark`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-set-value-refusal-\(UUID().uuidString)", isDirectory: true)
        let socketPath = "/tmp/peekaboo-set-value-refusal-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root.appendingPathComponent("watermarks"))
        let snapshots = InMemorySnapshotManager(desktopMutationWatermarkStore: store)
        let services = await MainActor.run { StubServices(snapshots: snapshots) }
        await MainActor.run {
            services.automationStub.elementActionError = DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Target process generation changed before desktop mutation.",
                standardErrorCode: .snapshotStale)
        }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: services,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                desktopMutationWatermarkStore: store)
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()

        do {
            let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
            _ = try await client.handshake(client: .init(
                bundleIdentifier: "dev.peekaboo.set-value-refusal-tests",
                teamIdentifier: nil,
                processIdentifier: getpid(),
                hostname: nil))
            let failure = await #expect(throws: DesktopActionFailure.self) {
                _ = try await client.setValueWithOutcome(
                    target: "T1",
                    value: .string("hello"),
                    snapshotId: "S1")
            }
            #expect(failure?.outcome.route == .bridge)
            #expect(failure?.outcome.state == .refused)
            #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
            #expect(failure?.outcome.retrySafety == .safe)
            #expect(failure?.standardErrorCode == .snapshotStale)
            #expect(store.effectiveWatermark() == nil)
            #expect(services.automationStub.lastSetValue == nil)
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }

    enum FailureTarget: CaseIterable {
        case process, exactWindow, wrongWindow, wrongGeneration

        var contradictsSnapshot: Bool {
            self == .wrongWindow || self == .wrongGeneration
        }
    }

    @Test(arguments: FailureTarget.allCases)
    @MainActor
    func `signed client preserves post-dispatch readback failure and target receipt`(
        target: FailureTarget) async throws
    {
        let socketPath = "/tmp/peekaboo-bridge-set-value-failure-\(UUID().uuidString).sock"
        let processGeneration = try #require(SystemIdentityResolver.processStartIdentity(getpid()))
        let bounds = CGRect(x: 10, y: 20, width: 640, height: 480)
        let windowIdentity = WindowMutationIdentity(
            windowID: 91,
            ownerProcessIdentifier: getpid(),
            ownerProcessStartIdentity: processGeneration,
            capturedBounds: bounds)
        let snapshotID = SnapshotReference.generate().rawValue
        let detection = ElementDetectionResult(
            snapshotId: snapshotID,
            screenshotPath: "",
            elements: DetectedElements(),
            metadata: .init(
                detectionTime: 0,
                elementCount: 0,
                method: "fixture",
                windowContext: WindowContext(
                    applicationName: "Fixture",
                    applicationProcessId: getpid(),
                    applicationProcessStartIdentity: processGeneration,
                    windowID: target == .process ? nil : windowIdentity.windowID,
                    windowBounds: target == .process ? nil : bounds,
                    windowMutationIdentity: target == .process ? nil : windowIdentity)))
        let snapshots = try await InMemorySnapshotManager.containing(detection)
        let services = StubServices(snapshots: snapshots)
        let targetReceipt = DesktopActionTargetReceipt(
            processIdentifier: getpid(),
            processStartIdentity: target == .wrongGeneration ? processGeneration + 1 : processGeneration,
            windowID: target == .process ? nil : (target == .wrongWindow ? 92 : 91))
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
                snapshotId: snapshotID)
            Issue.record("Expected typed set-value failure")
        } catch let failure as DesktopActionFailure {
            if target.contradictsSnapshot {
                #expect(failure.message == "Bridge operation completed without a trustworthy exact target receipt.")
                #expect(failure.targetReceipt == nil)
                let mismatch = target == .wrongWindow ? "different windows" : "different process generations"
                #expect(failure.causeDescription?.contains(mismatch) == true)
            } else {
                #expect(failure.message == "The submitted value could not be read back.")
                #expect(failure.targetReceipt == targetReceipt)
                #expect(failure.hint?.contains("Observe the exact target") == true)
            }
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == .init(mechanism: .accessibilityValue, mode: .background))
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.projection.requiresFreshObservation)
        }
    }
}
