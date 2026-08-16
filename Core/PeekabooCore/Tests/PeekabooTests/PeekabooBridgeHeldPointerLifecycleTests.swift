import CoreGraphics
import Foundation
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeHeldPointerLifecycleTests {
    private static let clientIdentity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peekaboo.held-pointer-tests",
        teamIdentifier: nil,
        processIdentifier: getpid())

    @Test
    func `held lifecycle keeps success counts exact while admitting truthful failure progress`() throws {
        let bounds = CGRect(x: 10, y: 20, width: 100, height: 80)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 9001,
            ownerProcessStartIdentity: 7,
            capturedBounds: bounds)
        let owner = ExactWindowHeldPointerOwner()
        let holdRequest = ExactWindowHeldPointerRequest(
            point: CGPoint(x: 20, y: 30),
            windowIdentity: identity,
            windowBounds: bounds,
            button: .left,
            expiresAfterSeconds: 10)
        let receipt = ExactWindowHeldPointerReceipt(
            token: UUID(),
            owner: owner,
            request: holdRequest,
            expiresAt: Date().addingTimeInterval(10))
        let begin = PeekabooBridgeRequest.beginExactWindowHeldPointer(.init(
            owner: owner,
            request: holdRequest))
        let release = PeekabooBridgeRequest.releaseExactWindowHeldPointer(.init(
            owner: owner,
            receipt: receipt))
        let disconnect = PeekabooBridgeRequest.disconnectExactWindowHeldPointerOwner(.init(owner: owner))
        let delivery = DesktopActionOutcome.Delivery(
            mechanism: .windowTargetedEvents,
            mode: .background)

        for count in [1, 2, 3] {
            let units = try #require(DesktopActionOutcome.DispatchUnitCount(count))
            let success = DesktopActionOutcome.dispatchedUnverified(
                route: .bridge,
                delivery: delivery,
                evidence: .deliveryAccepted,
                unitCount: units)
            #expect(
                PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
                    success,
                    request: begin) == (count == 2))
            let failure = DesktopActionFailure.indeterminate(
                route: .bridge,
                delivery: delivery,
                evidence: .completionUnknown,
                unitCount: units,
                message: "Held begin failure progress")
            #expect(
                PeekabooBridgeOperationResultSemantics.failureOutcomeMatchesContract(
                    failure.outcome,
                    request: begin) == [1, 2, 3].contains(count))
        }

        for count in [1, 2] {
            let units = try #require(DesktopActionOutcome.DispatchUnitCount(count))
            let success = DesktopActionOutcome.dispatchedUnverified(
                route: .bridge,
                delivery: delivery,
                evidence: .deliveryAccepted,
                unitCount: units)
            #expect(
                PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
                    success,
                    request: release) == (count == 1))
            let failure = DesktopActionFailure.partial(
                route: .bridge,
                delivery: delivery,
                unitCount: units,
                message: "Held terminal failure progress")
            #expect(
                PeekabooBridgeOperationResultSemantics.failureOutcomeMatchesContract(
                    failure.outcome,
                    request: release) == (count == 2))
        }
        #expect(PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            .confirmedNoChange(route: .bridge),
            request: disconnect))
    }

    @Test
    func `protocol 1 29 host is refused before held pointer request dispatch`() async throws {
        let fixture = await self.makeHost(protocolVersion: .init(major: 1, minor: 29))
        try await fixture.host.startChecked()
        defer { Task { await fixture.host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: fixture.socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(client: Self.clientIdentity)

        #expect(handshake.negotiatedVersion == .init(major: 1, minor: 29))
        #expect(!handshake.supportedOperations.contains(.createExactWindowHeldPointerOwner))
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.exactWindowHeldPointerLifecycle) != true)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.statelessClickVariants) != true)
        #expect(await client.exactWindowHeldPointerLifecycleEnabled == false)
        #expect(await client.exactWindowHeldPointerTerminalCleanupEnabled == false)
        #expect(await client.statelessClickVariantsEnabled == false)
        await #expect(throws: PeekabooError.self) {
            _ = try await client.createExactWindowHeldPointerOwner()
        }
        #expect(await fixture.automation.createCount == 0)
        await fixture.host.stop()
    }

    @Test
    func `protocol 1 30 transports owner bound down and release lifecycle`() async throws {
        let fixture = await self.makeHost(protocolVersion: PeekabooBridgeConstants.protocolVersion)
        try await fixture.host.startChecked()
        defer { Task { await fixture.host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: fixture.socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(client: Self.clientIdentity)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.exactWindowHeldPointerLifecycle) == true)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.statelessClickVariants) == true)
        #expect(handshake.supportedOperations.contains(.targetedClick))
        #expect(handshake.supportedOperations.contains(.exactWindowTargetedClick))
        #expect(handshake.enabledOperations?.contains(.targetedClick) == true)
        #expect(handshake.enabledOperations?.contains(.exactWindowTargetedClick) == true)
        #expect(await client.exactWindowHeldPointerLifecycleEnabled == true)
        #expect(await client.exactWindowHeldPointerTerminalCleanupEnabled == true)
        #expect(await client.statelessClickVariantsEnabled == true)

        let owner = try await client.createExactWindowHeldPointerOwner()
        let request = fixture.automation.request
        let begin = try await client.beginExactWindowPointerHold(owner: owner, request: request)
        #expect(begin.outcome?.dispatchState.unitCount?.rawValue == 2)
        #expect(begin.targetIdentity?.exactWindow?.identity == request.windowIdentity)

        let release = try await client.releaseExactWindowPointerHold(
            owner: owner,
            receipt: begin.payload)
        #expect(release.payload.reason == .released)
        #expect(release.outcome?.dispatchState.unitCount?.rawValue == 1)
        #expect(release.payload.lifecycleDispatchedUnitCount == 3)
        #expect(await fixture.automation.terminalDispatchCount == 1)
        let retry = try await client.revokeExactWindowPointerHold(
            owner: owner,
            receipt: begin.payload)
        #expect(retry.payload == release.payload)
        #expect(await fixture.automation.terminalDispatchCount == 1)

        let bundle = try #require(await client.lastOperationReceiptBundle())
        try bundle.validate()
        #expect(bundle.receipt.payload.target == .window(request.windowIdentity))
        await fixture.host.stop()
    }

    @Test
    func `terminal cleanup remains admitted after post event permission is lost`() async throws {
        let fixture = await self.makeHost(protocolVersion: PeekabooBridgeConstants.protocolVersion)
        try await fixture.host.startChecked()
        defer { Task { await fixture.host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: fixture.socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let owner = try await client.createExactWindowHeldPointerOwner()
        let begin = try await client.beginExactWindowPointerHold(
            owner: owner,
            request: fixture.automation.request)

        fixture.permissions.postEvent = false
        let refreshed = try await client.handshake(client: Self.clientIdentity)
        #expect(refreshed.enabledOperations?.contains(.beginExactWindowHeldPointer) == false)
        #expect(refreshed.enabledOperations?.contains(.releaseExactWindowHeldPointer) == true)
        #expect(await client.exactWindowHeldPointerLifecycleEnabled == false)
        #expect(await client.exactWindowHeldPointerTerminalCleanupEnabled == true)
        let terminal = try await client.releaseExactWindowPointerHold(owner: owner, receipt: begin.payload)

        #expect(terminal.payload.reason == .released)
        #expect(await fixture.automation.terminalDispatchCount == 1)
    }

    @Test
    func `input capability invalidation clears both protocol 1 30 approvals`() async throws {
        let fixture = await self.makeHost(protocolVersion: PeekabooBridgeConstants.protocolVersion)
        try await fixture.host.startChecked()
        defer { Task { await fixture.host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: fixture.socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        #expect(await client.exactWindowHeldPointerLifecycleEnabled)
        #expect(await client.exactWindowHeldPointerTerminalCleanupEnabled)
        #expect(await client.statelessClickVariantsEnabled)

        await client.clearNegotiatedInputCapabilities()

        #expect(await client.exactWindowHeldPointerLifecycleEnabled == false)
        #expect(await client.exactWindowHeldPointerTerminalCleanupEnabled == false)
        #expect(await client.statelessClickVariantsEnabled == false)
    }

    @Test
    func `protocol 1 30 removes stateless click capability when service opts out`() async throws {
        let fixture = await self.makeHost(
            protocolVersion: PeekabooBridgeConstants.protocolVersion,
            supportsStatelessClickVariants: false)
        try await fixture.host.startChecked()
        defer { Task { await fixture.host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: fixture.socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(client: Self.clientIdentity)

        #expect(handshake.supportedOperations.contains(.targetedClick))
        #expect(handshake.supportedOperations.contains(.exactWindowTargetedClick))
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.statelessClickVariants) != true)
        #expect(await client.statelessClickVariantsEnabled == false)
    }

    @Test
    func `protocol 1 30 removes held pointer capability when service opts out`() async throws {
        let fixture = await self.makeHost(
            protocolVersion: PeekabooBridgeConstants.protocolVersion,
            supportsExactWindowHeldPointerLifecycle: false)
        try await fixture.host.startChecked()
        defer { Task { await fixture.host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: fixture.socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(client: Self.clientIdentity)

        #expect(!handshake.supportedOperations.contains(.createExactWindowHeldPointerOwner))
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.exactWindowHeldPointerLifecycle) != true)
        #expect(await client.exactWindowHeldPointerLifecycleEnabled == false)
        #expect(await client.exactWindowHeldPointerTerminalCleanupEnabled == false)
    }

    @Test
    func `held lifecycle requires the exact negotiated session capability`() async throws {
        let fixture = await self.makeHost(protocolVersion: PeekabooBridgeConstants.protocolVersion)
        let owner = ExactWindowHeldPointerOwner()
        let receipt = ExactWindowHeldPointerReceipt(
            token: UUID(),
            owner: owner,
            request: fixture.automation.request,
            expiresAt: Date().addingTimeInterval(10))
        let requests: [PeekabooBridgeRequest] = [
            .createExactWindowHeldPointerOwner,
            .beginExactWindowHeldPointer(.init(owner: owner, request: fixture.automation.request)),
            .releaseExactWindowHeldPointer(.init(owner: owner, receipt: receipt)),
            .revokeExactWindowHeldPointer(.init(owner: owner, receipt: receipt)),
            .disconnectExactWindowHeldPointerOwner(.init(owner: owner)),
        ]
        let refusedSessions = [
            PeekabooBridgeNegotiatedSessionCapabilities(
                protocolVersion: .init(major: 1, minor: 29),
                statelessClickVariants: false,
                exactWindowHeldPointerLifecycle: false),
            PeekabooBridgeNegotiatedSessionCapabilities(
                protocolVersion: PeekabooBridgeConstants.protocolVersion,
                statelessClickVariants: true,
                exactWindowHeldPointerLifecycle: false),
        ]

        for session in refusedSessions {
            for request in requests {
                await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
                    _ = try await PeekabooBridgeRequestContext.$negotiatedSessionCapabilities.withValue(session) {
                        try await fixture.server.route(request, peer: nil)
                    }
                }
            }
        }
        #expect(await fixture.automation.createCount == 0)
        #expect(await fixture.automation.terminalDispatchCount == 0)
    }

    @Test
    func `wrong owner receipt refuses with zero terminal dispatch`() async throws {
        let fixture = await self.makeHost(protocolVersion: PeekabooBridgeConstants.protocolVersion)
        try await fixture.host.startChecked()
        defer { Task { await fixture.host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: fixture.socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let owner = try await client.createExactWindowHeldPointerOwner()
        let otherOwner = try await client.createExactWindowHeldPointerOwner()
        let begin = try await client.beginExactWindowPointerHold(
            owner: owner,
            request: fixture.automation.request)

        do {
            _ = try await client.releaseExactWindowPointerHold(
                owner: otherOwner,
                receipt: begin.payload)
            Issue.record("Expected wrong-owner refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
        }
        #expect(await fixture.automation.terminalDispatchCount == 0)
        _ = try await client.revokeExactWindowPointerHold(owner: owner, receipt: begin.payload)
        #expect(await fixture.automation.terminalDispatchCount == 1)
        await fixture.host.stop()
    }

    @Test
    func `Bridge owner disconnect reaches one terminal cleanup`() async throws {
        let fixture = await self.makeHost(protocolVersion: PeekabooBridgeConstants.protocolVersion)
        try await fixture.host.startChecked()
        defer { Task { await fixture.host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: fixture.socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let owner = try await client.createExactWindowHeldPointerOwner()
        let begin = try await client.beginExactWindowPointerHold(
            owner: owner,
            request: fixture.automation.request)

        let result = try await client.disconnectExactWindowHeldPointerOwner(owner)
        #expect(result.payload?.reason == .ownerDisconnected)
        #expect(result.outcome?.dispatchState.unitCount?.rawValue == 1)
        #expect(await fixture.automation.terminalDispatchCount == 1)
        let replay = try await client.releaseExactWindowPointerHold(owner: owner, receipt: begin.payload)
        #expect(replay.payload == result.payload)
        #expect(await fixture.automation.terminalDispatchCount == 1)
        await fixture.host.stop()
    }

    @Test
    func `Bridge disconnect wins an in flight begin before receipt delivery`() async throws {
        let fixture = await self.makeHost(protocolVersion: PeekabooBridgeConstants.protocolVersion)
        try await fixture.host.startChecked()
        defer { Task { await fixture.host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: fixture.socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let owner = try await client.createExactWindowHeldPointerOwner()
        let beginCompleted = HeldPointerBridgeTestGate()
        let resumeBegin = HeldPointerBridgeTestGate()
        await MainActor.run {
            fixture.automation.beginCompletionHook = {
                await beginCompleted.open()
                await resumeBegin.wait()
            }
        }

        let begin = Task {
            try await client.beginExactWindowPointerHold(owner: owner, request: fixture.automation.request)
        }
        await beginCompleted.wait()
        let disconnected = try await client.disconnectExactWindowHeldPointerOwner(owner)
        await resumeBegin.open()

        #expect(disconnected.payload?.reason == .ownerDisconnected)
        do {
            _ = try await begin.value
            Issue.record("Expected the disconnected begin receipt to fail closed")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .dispatchedUnverified)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 2)
            #expect(failure.targetReceipt == DesktopActionTargetReceipt(
                processIdentifier: fixture.automation.request.windowIdentity.ownerProcessIdentifier,
                processStartIdentity: fixture.automation.request.windowIdentity.ownerProcessStartIdentity,
                windowID: fixture.automation.request.windowIdentity.windowID))
        }
    }

    @Test
    func `zero dispatch disconnect termination replays through release and revoke`() async throws {
        let fixture = await self.makeHost(protocolVersion: PeekabooBridgeConstants.protocolVersion)
        try await fixture.host.startChecked()
        defer { Task { await fixture.host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: fixture.socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let owner = try await client.createExactWindowHeldPointerOwner()
        let beginQueued = HeldPointerBridgeTestGate()
        let resumeBegin = HeldPointerBridgeTestGate()
        await MainActor.run {
            fixture.automation.beginDispatchHook = {
                await beginQueued.open()
                await resumeBegin.wait()
            }
        }

        let begin = Task {
            try await client.beginExactWindowPointerHold(owner: owner, request: fixture.automation.request)
        }
        await beginQueued.wait()
        let disconnected = try await client.disconnectExactWindowHeldPointerOwner(owner)
        let terminal = try #require(disconnected.payload)
        await resumeBegin.open()
        await #expect(throws: DesktopActionFailure.self) {
            _ = try await begin.value
        }

        #expect(terminal.reason == .ownerDisconnected)
        #expect(terminal.lifecycleDispatchedUnitCount == 0)
        #expect(disconnected.outcome?.state == .confirmedNoChange)
        let release = try await client.releaseExactWindowPointerHold(owner: owner, receipt: terminal.receipt)
        let revoke = try await client.revokeExactWindowPointerHold(owner: owner, receipt: terminal.receipt)
        #expect(release.payload == terminal)
        #expect(revoke.payload == terminal)
        #expect(release.outcome?.state == .confirmedNoChange)
        #expect(revoke.outcome?.state == .confirmedNoChange)
        #expect(await fixture.automation.terminalDispatchCount == 0)
    }

    @Test
    func `racing disconnect failure retains pending begin target attribution`() async throws {
        let fixture = await self.makeHost(protocolVersion: PeekabooBridgeConstants.protocolVersion)
        try await fixture.host.startChecked()
        defer { Task { await fixture.host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: fixture.socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let owner = try await client.createExactWindowHeldPointerOwner()
        let beginCompleted = HeldPointerBridgeTestGate()
        let resumeBegin = HeldPointerBridgeTestGate()
        await MainActor.run {
            fixture.automation.disconnectFailure = .partial(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                unitCount: .init(2),
                message: "Held pointer cleanup did not complete")
            fixture.automation.beginCompletionHook = {
                await beginCompleted.open()
                await resumeBegin.wait()
            }
        }

        let begin = Task {
            try await client.beginExactWindowPointerHold(owner: owner, request: fixture.automation.request)
        }
        await beginCompleted.wait()
        do {
            _ = try await client.disconnectExactWindowHeldPointerOwner(owner)
            Issue.record("Expected the racing disconnect cleanup failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .partial)
            #expect(failure.targetReceipt == DesktopActionTargetReceipt(
                processIdentifier: fixture.automation.request.windowIdentity.ownerProcessIdentifier,
                processStartIdentity: fixture.automation.request.windowIdentity.ownerProcessStartIdentity,
                windowID: fixture.automation.request.windowIdentity.windowID))
        }
        await resumeBegin.open()

        await #expect(throws: DesktopActionFailure.self) {
            _ = try await begin.value
        }
        #expect(await MainActor.run {
            let binding = fixture.server.heldPointerBridgeOwners[owner]
            return binding?.closedAt != nil &&
                binding?.pendingBeginTarget?.exactWindow?.identity == fixture.automation.request.windowIdentity
        })
    }

    @Test
    @MainActor
    func `older terminal completion cannot clear a newer hold`() async {
        let fixture = await self.makeHost(protocolVersion: PeekabooBridgeConstants.protocolVersion)
        let owner = ExactWindowHeldPointerOwner()
        let first = ExactWindowHeldPointerReceipt(
            token: UUID(),
            owner: owner,
            request: fixture.automation.request,
            expiresAt: Date().addingTimeInterval(10))
        let second = ExactWindowHeldPointerReceipt(
            token: UUID(),
            owner: owner,
            request: fixture.automation.request,
            expiresAt: Date().addingTimeInterval(10))
        fixture.server.heldPointerBridgeOwners[owner] = PeekabooBridgeHeldPointerOwnerBinding(
            peerIdentity: ApplicationProcessIdentity(
                processIdentifier: getpid(),
                processStartIdentity: 1),
            pendingBeginTarget: nil,
            activeReceipt: first,
            closedAt: nil)

        fixture.server.heldPointerBridgeOwners[owner]?.activeReceipt = second
        fixture.server.clearHeldPointerActiveReceiptIfMatching(owner: owner, receipt: first)

        #expect(fixture.server.heldPointerBridgeOwners[owner]?.activeReceipt == second)
    }

    @Test
    func `Bridge disconnect cleanup failure retains exact target attribution`() async throws {
        let fixture = await self.makeHost(protocolVersion: PeekabooBridgeConstants.protocolVersion)
        try await fixture.host.startChecked()
        defer { Task { await fixture.host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: fixture.socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let owner = try await client.createExactWindowHeldPointerOwner()
        let begin = try await client.beginExactWindowPointerHold(owner: owner, request: fixture.automation.request)
        await MainActor.run {
            fixture.automation.disconnectFailure = .partial(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                unitCount: .init(2),
                message: "Held pointer cleanup did not complete")
        }

        do {
            _ = try await client.disconnectExactWindowHeldPointerOwner(owner)
            Issue.record("Expected exact disconnect cleanup failure")
        } catch let failure as DesktopActionFailure {
            if failure.outcome.state != .partial || failure.targetReceipt == nil {
                Issue.record("Unexpected disconnect failure: \(failure)")
            }
            #expect(failure.outcome.state == .partial)
            #expect(failure.targetReceipt == DesktopActionTargetReceipt(
                processIdentifier: fixture.automation.request.windowIdentity.ownerProcessIdentifier,
                processStartIdentity: fixture.automation.request.windowIdentity.ownerProcessStartIdentity,
                windowID: fixture.automation.request.windowIdentity.windowID))
        }
        #expect(await MainActor.run {
            fixture.server.heldPointerBridgeOwners[owner]?.closedAt != nil
        })
        await #expect(throws: DesktopActionFailure.self) {
            _ = try await client.releaseExactWindowPointerHold(owner: owner, receipt: begin.payload)
        }
        #expect(await fixture.automation.terminalDispatchCount == 1)
    }

    @Test
    func `Bridge disconnect closes an idle owner as signed no change`() async throws {
        let fixture = await self.makeHost(protocolVersion: PeekabooBridgeConstants.protocolVersion)
        try await fixture.host.startChecked()
        defer { Task { await fixture.host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: fixture.socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let owner = try await client.createExactWindowHeldPointerOwner()

        let result = try await client.disconnectExactWindowHeldPointerOwner(owner)
        #expect(result.payload == nil)
        #expect(result.outcome?.state == .confirmedNoChange)
        #expect(result.targetIdentity == nil)
        let bundle = try #require(await client.lastOperationReceiptBundle())
        try bundle.validate()
        #expect(bundle.receipt.payload.target == .global)

        await #expect(throws: DesktopActionFailure.self) {
            _ = try await client.disconnectExactWindowHeldPointerOwner(owner)
        }
        await fixture.host.stop()
    }

    @Test
    func `closed Bridge owner retention is bounded at completion`() async throws {
        let fixture = await self.makeHost(protocolVersion: PeekabooBridgeConstants.protocolVersion)
        try await fixture.host.startChecked()
        defer { Task { await fixture.host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: fixture.socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)

        for _ in 0..<260 {
            let owner = try await client.createExactWindowHeldPointerOwner()
            _ = try await client.beginExactWindowPointerHold(owner: owner, request: fixture.automation.request)
            _ = try await client.disconnectExactWindowHeldPointerOwner(owner)
        }

        #expect(await MainActor.run {
            fixture.server.retainedClosedHeldPointerOwnerCountForTesting == 256
        })
    }

    @Test
    func `failed disconnect Bridge owner retention is bounded at completion`() async throws {
        let fixture = await self.makeHost(protocolVersion: PeekabooBridgeConstants.protocolVersion)
        try await fixture.host.startChecked()
        defer { Task { await fixture.host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: fixture.socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        await MainActor.run {
            fixture.automation.disconnectFailure = .partial(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                unitCount: .init(2),
                message: "Held pointer cleanup did not complete")
        }

        for _ in 0..<260 {
            let owner = try await client.createExactWindowHeldPointerOwner()
            _ = try await client.beginExactWindowPointerHold(owner: owner, request: fixture.automation.request)
            await #expect(throws: DesktopActionFailure.self) {
                _ = try await client.disconnectExactWindowHeldPointerOwner(owner)
            }
        }

        #expect(await MainActor.run {
            fixture.server.retainedClosedHeldPointerOwnerCountForTesting == 256
        })
    }

    private func makeHost(
        protocolVersion: PeekabooBridgeProtocolVersion,
        supportsStatelessClickVariants: Bool = true,
        supportsExactWindowHeldPointerLifecycle: Bool = true) async -> HostFixture
    {
        await MainActor.run {
            let automation = HeldPointerBridgeAutomationStub(
                supportsStatelessClickVariants: supportsStatelessClickVariants,
                supportsExactWindowHeldPointerLifecycle: supportsExactWindowHeldPointerLifecycle)
            let permissions = HeldPointerPermissionState()
            let services = StubServices(
                automation: automation,
                ownedDesktopOperationLanes: [
                    .beginExactWindowHeldPointer,
                    .releaseExactWindowHeldPointer,
                    .revokeExactWindowHeldPointer,
                    .disconnectExactWindowHeldPointerOwner,
                ])
            let socketPath = "/tmp/peekaboo-held-pointer-\(UUID().uuidString).sock"
            let server = PeekabooBridgeServer(
                services: services,
                allowlistedTeams: [],
                allowlistedBundles: [],
                supportedVersions: protocolVersion...protocolVersion,
                allowedOperations: [
                    .targetedClick,
                    .exactWindowTargetedClick,
                    .createExactWindowHeldPointerOwner,
                    .beginExactWindowHeldPointer,
                    .releaseExactWindowHeldPointer,
                    .revokeExactWindowHeldPointer,
                    .disconnectExactWindowHeldPointerOwner,
                ],
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(
                        screenRecording: true,
                        accessibility: true,
                        postEvent: permissions.postEvent)
                })
            return HostFixture(
                socketPath: socketPath,
                server: server,
                host: PeekabooBridgeHost(
                    socketPath: socketPath,
                    server: server,
                    allowedTeamIDs: [],
                    requestTimeoutSec: 2),
                permissions: permissions,
                automation: automation)
        }
    }
}

private struct HostFixture: Sendable {
    let socketPath: String
    let server: PeekabooBridgeServer
    let host: PeekabooBridgeHost
    let permissions: HeldPointerPermissionState
    let automation: HeldPointerBridgeAutomationStub
}

private final class HeldPointerPermissionState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPostEvent = true

    var postEvent: Bool {
        get { self.lock.withLock { self.storedPostEvent } }
        set { self.lock.withLock { self.storedPostEvent = newValue } }
    }
}

@MainActor
private final class HeldPointerBridgeAutomationStub:
    ExactWindowHeldPointerLifecycleServiceProtocol,
    ExactWindowTargetedClickServiceProtocol
{
    let supportsExactWindowHeldPointerLifecycle: Bool
    let supportsStatelessClickVariants: Bool
    let supportsExactWindowTargetedClicks = true
    private(set) var createCount = 0
    private(set) var terminalDispatchCount = 0
    var disconnectFailure: DesktopActionFailure?
    var beginDispatchHook: (@MainActor @Sendable () async -> Void)?
    var beginCompletionHook: (@MainActor @Sendable () async -> Void)?
    private var owners: Set<ExactWindowHeldPointerOwner> = []
    private var queued: [ExactWindowHeldPointerOwner: ExactWindowHeldPointerReceipt] = [:]
    private var active: [ExactWindowHeldPointerOwner: ExactWindowHeldPointerReceipt] = [:]
    private var completed: [ExactWindowHeldPointerOwner: UIAutomationActionResult<ExactWindowHeldPointerTermination>] =
        [:]
    private var failed: [ExactWindowHeldPointerOwner: (ExactWindowHeldPointerReceipt, DesktopActionFailure)] = [:]
    let request: ExactWindowHeldPointerRequest

    init(
        supportsStatelessClickVariants: Bool,
        supportsExactWindowHeldPointerLifecycle: Bool)
    {
        self.supportsStatelessClickVariants = supportsStatelessClickVariants
        self.supportsExactWindowHeldPointerLifecycle = supportsExactWindowHeldPointerLifecycle
        let bounds = CGRect(x: 10, y: 20, width: 400, height: 300)
        self.request = ExactWindowHeldPointerRequest(
            point: CGPoint(x: 50, y: 60),
            windowIdentity: WindowMutationIdentity(
                windowID: 901,
                ownerProcessIdentifier: 77001,
                ownerProcessStartIdentity: 88,
                capturedBounds: bounds),
            windowBounds: bounds,
            button: .left,
            expiresAfterSeconds: 10)
    }

    func click(
        target _: ClickTarget,
        clickType _: ClickType,
        snapshotId _: String?,
        targetProcessIdentifier _: pid_t) async throws
    {}

    func click(
        target _: ClickTarget,
        clickType _: ClickType,
        snapshotId _: String?,
        expectedWindowIdentity _: WindowMutationIdentity,
        expectedWindowBounds _: CGRect) async throws
    {}

    func createExactWindowHeldPointerOwner(
        boundTo _: ApplicationProcessIdentity?) async throws -> ExactWindowHeldPointerOwner
    {
        self.createCount += 1
        let owner = ExactWindowHeldPointerOwner()
        self.owners.insert(owner)
        return owner
    }

    func beginExactWindowPointerHold(
        owner: ExactWindowHeldPointerOwner,
        request: ExactWindowHeldPointerRequest) async throws
        -> UIAutomationActionResult<ExactWindowHeldPointerReceipt>
    {
        guard self.owners.contains(owner), self.queued[owner] == nil, self.active[owner] == nil else {
            throw ExactWindowHeldPointerLifecycleError.ownerUnknown
        }
        let receipt = ExactWindowHeldPointerReceipt(
            token: UUID(),
            owner: owner,
            request: request,
            expiresAt: Date().addingTimeInterval(request.expiresAfterSeconds))
        if let beginDispatchHook {
            self.queued[owner] = receipt
            await beginDispatchHook()
            self.beginDispatchHook = nil
            guard self.queued.removeValue(forKey: owner) == receipt,
                  self.owners.contains(owner)
            else {
                throw ExactWindowHeldPointerLifecycleError.ownerDisconnectedBeforeDispatch
            }
        }
        self.active[owner] = receipt
        let result = try UIAutomationActionResult(
            payload: receipt,
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .init(2)),
            targetIdentity: DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
                identity: request.windowIdentity,
                bounds: request.windowBounds)))
        await self.beginCompletionHook?()
        self.beginCompletionHook = nil
        return result
    }

    func releaseExactWindowPointerHold(
        owner: ExactWindowHeldPointerOwner,
        receipt: ExactWindowHeldPointerReceipt) async throws
        -> UIAutomationActionResult<ExactWindowHeldPointerTermination>
    {
        try self.terminate(owner: owner, receipt: receipt, reason: .released)
    }

    func revokeExactWindowPointerHold(
        owner: ExactWindowHeldPointerOwner,
        receipt: ExactWindowHeldPointerReceipt) async throws
        -> UIAutomationActionResult<ExactWindowHeldPointerTermination>
    {
        try self.terminate(owner: owner, receipt: receipt, reason: .revoked)
    }

    func disconnectExactWindowHeldPointerOwner(
        _ owner: ExactWindowHeldPointerOwner) async throws
        -> UIAutomationActionResult<ExactWindowHeldPointerTermination?>
    {
        if let receipt = self.queued.removeValue(forKey: owner) {
            self.owners.remove(owner)
            let terminal = ExactWindowHeldPointerTermination(
                receipt: receipt,
                reason: .ownerDisconnected,
                cleanupOutcome: .confirmedNoChange(),
                lifecycleDispatchedUnitCount: 0)
            let completed = try UIAutomationActionResult(
                payload: terminal,
                outcome: .confirmedNoChange(),
                targetIdentity: DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
                    identity: receipt.windowIdentity,
                    bounds: receipt.windowBounds)))
            self.completed[owner] = completed
            return UIAutomationActionResult(
                payload: terminal,
                outcome: completed.outcome,
                targetIdentity: completed.targetIdentity)
        }
        guard let receipt = self.active[owner] else {
            guard self.owners.remove(owner) != nil else {
                throw ExactWindowHeldPointerLifecycleError.ownerUnknown
            }
            return UIAutomationActionResult(
                payload: nil,
                outcome: .confirmedNoChange(),
                targetIdentity: nil)
        }
        if let disconnectFailure {
            self.active.removeValue(forKey: owner)
            self.owners.remove(owner)
            self.failed[owner] = (receipt, disconnectFailure)
            self.terminalDispatchCount += 1
            throw disconnectFailure
        }
        let result = try self.terminate(owner: owner, receipt: receipt, reason: .ownerDisconnected)
        self.owners.remove(owner)
        return UIAutomationActionResult(
            payload: result.payload,
            outcome: result.outcome,
            targetIdentity: result.targetIdentity)
    }

    private func terminate(
        owner: ExactWindowHeldPointerOwner,
        receipt: ExactWindowHeldPointerReceipt,
        reason: ExactWindowHeldPointerTerminalReason) throws
        -> UIAutomationActionResult<ExactWindowHeldPointerTermination>
    {
        guard self.active[owner] == receipt else {
            if let completed = self.completed[owner], completed.payload.receipt == receipt {
                return completed
            }
            if let failed = self.failed[owner], failed.0 == receipt {
                throw failed.1
            }
            throw ExactWindowHeldPointerLifecycleError.ownerMismatch
        }
        self.active.removeValue(forKey: owner)
        self.terminalDispatchCount += 1
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let terminal = ExactWindowHeldPointerTermination(
            receipt: receipt,
            reason: reason,
            cleanupOutcome: outcome,
            lifecycleDispatchedUnitCount: 3)
        let result = try UIAutomationActionResult(
            payload: terminal,
            outcome: outcome,
            targetIdentity: DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
                identity: receipt.windowIdentity,
                bounds: receipt.windowBounds)))
        self.completed[owner] = result
        return result
    }

    func detectElements(in _: Data, snapshotId _: String?, windowContext _: WindowContext?) async throws
    -> ElementDetectionResult {
        throw PeekabooError.notImplemented("test")
    }

    func click(target _: ClickTarget, clickType _: ClickType, snapshotId _: String?) async throws {}
    func type(
        text _: String,
        target _: String?,
        clearExisting _: Bool,
        typingDelay _: Int,
        snapshotId _: String?) async throws {}
    func typeActions(_: [TypeAction], cadence _: TypingCadence, snapshotId _: String?) async throws -> TypeResult {
        TypeResult(totalCharacters: 0, keyPresses: 0)
    }

    func scroll(_: ScrollRequest) async throws {}
    func hotkey(keys _: String, holdDuration _: Int) async throws {}
    func swipe(
        from _: CGPoint,
        to _: CGPoint,
        duration _: Int,
        steps _: Int,
        profile _: MouseMovementProfile) async throws {}
    func hasAccessibilityPermission() async -> Bool {
        true
    }

    func waitForElement(target _: ClickTarget, timeout _: TimeInterval, snapshotId _: String?) async throws
    -> WaitForElementResult {
        throw PeekabooError.notImplemented("test")
    }

    func drag(_: DragOperationRequest) async throws {}
    func moveMouse(to _: CGPoint, duration _: Int, steps _: Int, profile _: MouseMovementProfile) async throws {}
    func getFocusedElement() -> UIFocusInfo? {
        nil
    }

    func findElement(matching _: UIElementSearchCriteria, in _: String?) async throws -> DetectedElement {
        throw PeekabooError.notImplemented("test")
    }
}

private actor HeldPointerBridgeTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !self.isOpen else { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }

    func open() {
        self.isOpen = true
        let waiters = self.waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
