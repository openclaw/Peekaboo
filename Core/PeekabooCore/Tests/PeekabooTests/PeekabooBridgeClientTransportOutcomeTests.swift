import CoreGraphics
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

@Suite(.serialized)
struct PeekabooBridgeClientTransportOutcomeTests {
    @Test
    func `mutation response timeout is indeterminate and retry unsafe`() async throws {
        let peer = try Self.receiptlessPeer(steps: [.idle(seconds: 0.15)])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 0.05)
        try await Self.negotiateReceiptless(client)

        do {
            try await client.sendExpectOK(Self.clickRequest)
            Issue.record("Expected the response read to time out")
        } catch let failure as DesktopActionFailure {
            Self.expectResponseLostFailure(failure)
        }
        await peer.waitUntilFinished()
    }

    @Test
    func `read-only response timeout remains an ordinary transport failure`() async throws {
        let peer = try Self.receiptlessPeer(steps: [.idle(seconds: 0.15)])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 0.05)
        try await Self.negotiateReceiptless(client)

        do {
            _ = try await client.send(.permissionsStatus)
            Issue.record("Expected the response read to time out")
        } catch let error as POSIXError {
            #expect(error.code == .ETIMEDOUT)
        }
        await peer.waitUntilFinished()
    }

    @Test
    func `handshake timeout is shared across protocol fallback attempts`() async throws {
        let versionMismatch = BridgeTestFixtures.errorResponse(
            code: .versionMismatch,
            message: "scripted version mismatch")
        let peer = try ScriptedBridgePeer(scripts: [
            [.delay(seconds: 0.3), .respond(versionMismatch)],
            [.idle(seconds: 5)],
        ])
        let client = TrustedBridgeClientFixture.make(socketPath: peer.socketPath, requestTimeoutSec: 1)
        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peekaboo.tests",
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: nil)
        let startedAt = ContinuousClock.now

        do {
            _ = try await client.handshake(client: identity, overallTimeoutSec: 1)
            Issue.record("Expected the negotiated handshake to exhaust its shared deadline")
        } catch let error as POSIXError {
            #expect(error.code == .ETIMEDOUT)
        }

        let elapsed = startedAt.duration(to: .now)
        #expect(elapsed >= .milliseconds(850))
        #expect(elapsed < .milliseconds(1200))
        #expect(await peer.acceptedConnectionCount == 2)
        await peer.stop()
    }

    @Test
    func `stop unblocks an accepted client before request EOF and is idempotent`() async throws {
        let peer = try ScriptedBridgePeer(steps: [.idle(seconds: 5)])
        let client = try Self.connectRawClient(to: peer.socketPath)
        defer { Darwin.close(client) }
        #expect(await Self.waitUntilAccepted(peer))

        let startedAt = ContinuousClock.now
        await peer.stop()
        #expect(startedAt.duration(to: .now) < .seconds(1))
        await peer.stop()
    }

    @Test
    func `stop wakes an idle accept before any client connects`() async throws {
        let peer = try ScriptedBridgePeer(steps: [.idle(seconds: 5)])
        let startedAt = ContinuousClock.now

        await peer.stop()

        #expect(startedAt.duration(to: .now) < .seconds(1))
        #expect(!FileManager.default.fileExists(atPath: peer.socketPath))
    }

    @Test
    func `deinit unblocks an accepted client before request EOF`() async throws {
        var peer: ScriptedBridgePeer? = try ScriptedBridgePeer(steps: [.idle(seconds: 5)])
        let client = try Self.connectRawClient(to: #require(peer).socketPath)
        defer { Darwin.close(client) }
        let accepted = try await Self.waitUntilAccepted(#require(peer))
        #expect(accepted)

        peer = nil
        var descriptor = pollfd(fd: client, events: Int16(POLLIN | POLLHUP), revents: 0)
        #expect(Darwin.poll(&descriptor, 1, 1000) == 1)
        #expect(descriptor.revents & Int16(POLLIN | POLLHUP) != 0)
    }

    @Test
    func `deinit wakes an idle accept before any client connects`() async throws {
        var peer: ScriptedBridgePeer? = try ScriptedBridgePeer(steps: [.idle(seconds: 5)])
        let socketPath = try #require(peer).socketPath

        peer = nil

        #expect(await Self.waitUntilSocketRemoved(socketPath))
    }

    @Test
    func `mutation response EOF is indeterminate and retry unsafe`() async throws {
        let peer = try Self.receiptlessPeer(steps: [.close])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        try await Self.negotiateReceiptless(client)

        do {
            try await client.sendExpectOK(Self.clickRequest)
            Issue.record("Expected response EOF")
        } catch let failure as DesktopActionFailure {
            Self.expectResponseLostFailure(failure)
        }
        await peer.waitUntilFinished()
    }

    @Test
    func `read-only response EOF remains retry safe`() async throws {
        let peer = try Self.receiptlessPeer(steps: [.close])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        try await Self.negotiateReceiptless(client)

        do {
            _ = try await client.send(.permissionsStatus)
            Issue.record("Expected response EOF")
        } catch let error as PeekabooBridgeErrorEnvelope {
            #expect(error.code == .internalError)
            #expect(!error.operationMayHaveCompleted)
        }
        await peer.waitUntilFinished()
    }

    @Test
    func `mutation malformed response is indeterminate and retry unsafe`() async throws {
        let peer = try Self.receiptlessPeer(steps: [.respondData(Data("not-json".utf8))])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        try await Self.negotiateReceiptless(client)

        do {
            try await client.sendExpectOK(Self.clickRequest)
            Issue.record("Expected response decoding failure")
        } catch let failure as DesktopActionFailure {
            Self.expectResponseLostFailure(failure)
        }
        await peer.waitUntilFinished()
    }

    @Test
    func `mutation connect failure remains retry safe`() async throws {
        let peer = try ScriptedBridgePeer(responses: [.handshake(Self.receiptlessHandshake)])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 0.05)
        try await Self.negotiateReceiptless(client)
        await peer.waitUntilFinished()

        do {
            try await client.sendExpectOK(Self.clickRequest)
            Issue.record("Expected connect failure")
        } catch let error as PeekabooBridgeErrorEnvelope {
            Issue.record("Pre-send failure must not become an indeterminate envelope: \(error)")
        } catch let error as POSIXError {
            #expect(error.code == .ENOENT || error.code == .ECONNREFUSED)
        } catch {
            Issue.record("Expected POSIX connect failure, got \(error)")
        }
    }

    @Test
    @MainActor
    func `remote targeted click maps response loss to retry-unsafe delivery`() async throws {
        let peer = try Self.receiptlessPeer(steps: [.idle(seconds: 0.15)])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 0.05)
        try await Self.negotiateReceiptless(client)
        let remote = RemoteUIAutomationService(
            client: client,
            supportsTargetedClicks: true)

        do {
            try await remote.click(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .single,
                snapshotId: nil,
                targetProcessIdentifier: 42)
            Issue.record("Expected indeterminate targeted click delivery")
        } catch let failure as DesktopActionFailure {
            Self.expectResponseLostFailure(failure)
        }
        await peer.waitUntilFinished()
    }

    @Test
    func `canonical action failures reconstruct exactly once in shared transport`() async throws {
        let delivery = DesktopActionOutcome.Delivery(
            mechanism: .accessibilityAction,
            mode: .background)
        let twoUnits = try #require(DesktopActionOutcome.DispatchUnitCount(2))
        let targetReceipt = DesktopActionTargetReceipt(
            processIdentifier: 42,
            processStartIdentity: 9_007_199_254_740_993,
            windowID: 73)
        let failures = [
            DesktopActionFailure.refused(
                route: .bridge,
                reason: .permissionDenied,
                message: "Accessibility permission was refused",
                hint: "Grant Accessibility permission.",
                causeDescription: "AX is not trusted"),
            DesktopActionFailure.dispatchedUnverified(
                route: .bridge,
                delivery: delivery,
                evidence: .deliveryAccepted,
                unitCount: twoUnits,
                message: "Delivery was accepted but not verified",
                hint: "Observe before retrying.",
                causeDescription: "post-dispatch verification timed out")
                .attributed(to: targetReceipt),
            DesktopActionFailure.partial(
                route: .bridge,
                delivery: delivery,
                unitCount: twoUnits,
                message: "The action changed the target but cleanup failed",
                hint: "Recover the remaining side effect.",
                causeDescription: "cleanup receipt was unavailable"),
            DesktopActionFailure.indeterminate(
                route: .bridge,
                delivery: delivery,
                evidence: .completionUnknown,
                unitCount: twoUnits,
                message: "The final action state is unknown",
                hint: "Observe before retrying.",
                causeDescription: "the host lost its verification receipt"),
        ]

        for expected in failures {
            let response = BridgeTestFixtures.actionFailureResponse(failure: expected)
            let peer = try Self.receiptlessPeer(steps: [.respond(response)])
            let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
            try await Self.negotiateReceiptless(client)

            do {
                try await client.sendExpectOK(Self.clickRequest)
                Issue.record("Expected canonical desktop action failure")
            } catch let actual as DesktopActionFailure {
                #expect(actual == expected)
            }
            await peer.waitUntilFinished()
        }
    }

    @Test
    func `legacy may-have-completed response becomes completion-unknown`() async throws {
        let response = BridgeTestFixtures.errorResponse(
            code: .internalError,
            message: "Legacy host could not verify completion",
            details: "legacy detail",
            operationMayHaveCompleted: true)
        let peer = try Self.receiptlessPeer(steps: [.respond(response)])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        try await Self.negotiateReceiptless(client)

        do {
            try await client.sendExpectOK(Self.clickRequest)
            Issue.record("Expected conservative legacy desktop action failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.evidence == .completionUnknown)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.projection.requiresFreshObservation)
            #expect(failure.message == "Legacy host could not verify completion")
            #expect(failure.causeDescription == "legacy detail")
        }
        await peer.waitUntilFinished()
    }

    @Test
    func `read-only request never reconstructs a desktop action failure`() async throws {
        let failure = DesktopActionFailure.indeterminate(
            route: .bridge,
            evidence: .completionUnknown,
            message: "Fixture action failure on a read-only request")
        let response = BridgeTestFixtures.actionFailureResponse(failure: failure)
        let peer = try Self.receiptlessPeer(steps: [.respond(response)])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        try await Self.negotiateReceiptless(client)

        let actual = try await client.send(.permissionsStatus)
        guard case let .error(envelope) = actual else {
            Issue.record("Expected the read-only request to retain its Bridge error envelope")
            await peer.waitUntilFinished()
            return
        }
        #expect(envelope.desktopActionFailure == failure)
        await peer.waitUntilFinished()
    }

    @Test
    func `error envelope rejects compatibility Boolean contradicting canonical outcome`() throws {
        let failure = DesktopActionFailure.indeterminate(
            route: .bridge,
            evidence: .completionUnknown,
            message: "Completion unknown")
        let envelope = PeekabooBridgeErrorEnvelope(code: .internalError, actionFailure: failure)
        let data = try JSONEncoder.peekabooBridgeEncoder().encode(envelope)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["operationMayHaveCompleted"] = false
        let forged = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeErrorEnvelope.self, from: forged)
        }
    }

    @Test
    func `desktop mutation classifier covers input delivery but not read-only status`() {
        #expect(Self.clickRequest.mayMutateDesktop)
        #expect(PeekabooBridgeRequest.typeActions(.init(
            actions: [.text("x")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil)).mayMutateDesktop)
        #expect(PeekabooBridgeRequest.hotkey(.init(keys: "cmd,a", holdDuration: 0)).mayMutateDesktop)
        #expect(!PeekabooBridgeRequest.permissionsStatus.mayMutateDesktop)
    }

    @Test
    func `receiptless projection accepts a request-matched successful outcome`() async throws {
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let peer = try Self.projectedReceiptlessPeer(response: .projectedAction(.init(
            response: .ok,
            outcome: outcome.projection)))
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        try await Self.negotiateReceiptless(client)

        try await client.sendExpectOK(Self.moveMouseRequest)
        await peer.waitUntilFinished()
    }

    @Test
    func `receiptless projection keeps an absent legacy outcome compatible`() async throws {
        let peer = try Self.projectedReceiptlessPeer(response: .projectedAction(.init(
            response: .ok,
            outcome: nil)))
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        try await Self.negotiateReceiptless(client)

        try await client.sendExpectOK(Self.moveMouseRequest)
        await peer.waitUntilFinished()
    }

    @Test
    func `receiptless projection accepts an exact request-pinned target`() async throws {
        let identity = WindowMutationIdentity(
            windowID: 77,
            ownerProcessIdentifier: 420,
            ownerProcessStartIdentity: 9001,
            capturedBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let request = PeekabooBridgeRequest.focusWindow(.init(
            target: .windowId(identity.windowID),
            expectedIdentity: identity))
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let peer = try Self.projectedReceiptlessPeer(response: .projectedAction(.init(
            response: .ok,
            outcome: outcome.projection)))
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        try await Self.negotiateReceiptless(client)

        try await client.sendExpectOK(request)
        await peer.waitUntilFinished()
    }

    @Test
    func `legacy hide projection stays unpinned without claiming a receipt`() async throws {
        let outcome = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: .one)
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(Self.projectedReceiptlessHandshake),
            .projectedAction(.init(response: .ok, outcome: outcome.projection)),
        ])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        try await Self.negotiateReceiptless(client)

        let result = try await client.hideApplicationTargetedResult(identifier: "Fixture")
        await peer.waitUntilFinished()

        #expect(result.outcome == outcome)
        #expect(result.targetIdentity == nil)
        let requests = await peer.requests
        let hideRequest = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeRequest.self,
            from: requests[1])
        guard case let .projectedAction(projected) = hideRequest,
              case let .hideApplication(payload) = projected.request
        else {
            Issue.record("Expected projected legacy application hide")
            return
        }
        #expect(payload.identifier == "Fixture")
        #expect(payload.expectedIdentity == nil)
    }

    @Test
    func `receiptless projection validates browser progress and connection target`() async throws {
        let receipt = Self.browserConnectionReceipt
        let request = PeekabooBridgeRequest.browserExecute(.init(
            calls: [.init(toolName: "fixture", arguments: [:])],
            channel: receipt.channel,
            expectedConnectionReceipt: receipt))
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let response = PeekabooBridgeBrowserToolResponse(
            content: [],
            isError: false,
            meta: nil,
            connectionReceipt: receipt,
            completedCallCount: 1,
            dispatchedCallCount: 1)
        let peer = try Self.projectedReceiptlessPeer(response: .projectedAction(.init(
            response: .browserToolResponse(response),
            outcome: outcome.projection)))
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        try await Self.negotiateReceiptless(client)

        let reply = try await client.sendCarryingActionOutcome(request)
        #expect(reply.outcome == outcome.projection)
        await peer.waitUntilFinished()
    }

    @Test
    func `receiptless browser connect projection binds its exact endpoint and channel`() async throws {
        let request = PeekabooBridgeRequest.browserConnect(.init(
            channel: "stable",
            browserURL: "HTTP://LOCALHOST:9222"))
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let validReceipt = PeekabooBridgeBrowserConnectionReceipt(
            channel: "stable",
            browserURL: "http://localhost:9222/",
            webSocketDebuggerURL: "ws://localhost:9222/devtools/browser/browser-a",
            devToolsBrowserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")

        func projected(_ receipt: PeekabooBridgeBrowserConnectionReceipt) -> PeekabooBridgeResponse {
            .projectedAction(.init(
                response: .browserStatus(.init(
                    isConnected: true,
                    toolCount: 1,
                    detectedBrowsers: [],
                    connectionReceipt: receipt)),
                outcome: outcome.projection))
        }

        let validPeer = try Self.projectedReceiptlessPeer(response: projected(validReceipt))
        let validClient = PeekabooBridgeClient(socketPath: validPeer.socketPath, requestTimeoutSec: 1)
        try await Self.negotiateReceiptless(validClient)
        let validReply = try await validClient.sendCarryingActionOutcome(request)
        #expect(validReply.outcome == outcome.projection)
        await validPeer.waitUntilFinished()

        let wrongReceipts = [
            PeekabooBridgeBrowserConnectionReceipt(
                channel: "stable",
                browserURL: "http://localhost:9333/",
                webSocketDebuggerURL: "ws://localhost:9333/devtools/browser/browser-a",
                devToolsBrowserID: "browser-a",
                browserVersion: "Chrome/151.0",
                protocolVersion: "1.3"),
            PeekabooBridgeBrowserConnectionReceipt(
                channel: "canary",
                browserURL: "http://localhost:9222/",
                webSocketDebuggerURL: "ws://localhost:9222/devtools/browser/browser-a",
                devToolsBrowserID: "browser-a",
                browserVersion: "Chrome/151.0",
                protocolVersion: "1.3"),
            PeekabooBridgeBrowserConnectionReceipt(
                channel: "stable",
                processIdentifier: 42,
                processStartIdentity: 9001,
                bundleIdentifier: "com.google.Chrome"),
        ]
        for receipt in wrongReceipts {
            let peer = try Self.projectedReceiptlessPeer(response: projected(receipt))
            let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
            try await Self.negotiateReceiptless(client)
            do {
                _ = try await client.sendCarryingActionOutcome(request)
                Issue.record("Expected receiptless browser target substitution to be response loss")
            } catch let failure as DesktopActionFailure {
                Self.expectResponseLostFailure(failure)
            }
            await peer.waitUntilFinished()
        }
    }

    @Test(arguments: [
        ReceiptlessProjectedMismatch.okWithRefusal,
        .wrongResponseFamily,
        .wrongRoute,
        .wrongDelivery,
        .wrongDispatchCount,
        .browserProgressCountMismatch,
        .missingHandlerTarget,
        .contradictoryRequestPinnedTarget,
    ])
    func `receiptless projected outcome contradictions fail as response loss`(
        mismatch: ReceiptlessProjectedMismatch) async throws
    {
        let fixture = try mismatch.fixture()
        let peer = try Self.projectedReceiptlessPeer(response: fixture.response)
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        try await Self.negotiateReceiptless(client)

        do {
            try await client.sendExpectOK(fixture.request)
            Issue.record("Expected receiptless projected response validation to fail")
        } catch let failure as DesktopActionFailure {
            Self.expectResponseLostFailure(failure)
            #expect(failure.causeDescription?.contains(
                "Receiptless Bridge action projection validation failed") == true)
        }
        await peer.waitUntilFinished()
    }

    @Test
    func `receiptless projected refusal preserves its canonical action failure`() async throws {
        let failure = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .permissionDenied,
            message: "Accessibility permission was refused")
        let envelope = PeekabooBridgeErrorEnvelope(code: .permissionDenied, actionFailure: failure)
        let peer = try Self.projectedReceiptlessPeer(response: .projectedAction(.init(
            response: .error(envelope),
            outcome: failure.outcome.projection)))
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        try await Self.negotiateReceiptless(client)

        do {
            try await client.sendExpectOK(Self.moveMouseRequest)
            Issue.record("Expected the projected refusal")
        } catch let actual as DesktopActionFailure {
            #expect(actual == failure)
        }
        await peer.waitUntilFinished()
    }

    private static let clickRequest = PeekabooBridgeRequest.click(.init(
        target: .coordinates(CGPoint(x: 10, y: 20)),
        clickType: .single))

    private static let moveMouseRequest = PeekabooBridgeRequest.moveMouse(.init(
        to: CGPoint(x: 10, y: 20),
        duration: 0,
        steps: 1,
        profile: .linear))

    private static let browserConnectionReceipt = PeekabooBridgeBrowserConnectionReceipt(
        channel: "chrome",
        processIdentifier: 42,
        processStartIdentity: 9001,
        bundleIdentifier: "com.google.Chrome")

    private static let receiptlessProtocolVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 28)

    private static let receiptlessHandshake = BridgeTestFixtures.handshake(
        negotiatedVersion: Self.receiptlessProtocolVersion,
        supportedOperations: [
            .click,
            .permissionsStatus,
            .targetedClick,
            .moveMouse,
            .browserConnect,
            .browserExecute,
            .hideApplication,
            .unhideApplication,
            .focusWindow,
        ])

    private static let projectedReceiptlessHandshake = BridgeTestFixtures.handshake(
        negotiatedVersion: Self.receiptlessProtocolVersion,
        supportedOperations: Self.receiptlessHandshake.supportedOperations,
        hostCapabilities: [PeekabooBridgeHostCapability.desktopActionOutcomeProjection])

    private static func receiptlessPeer(steps: [ScriptedBridgePeer.Step]) throws -> ScriptedBridgePeer {
        try ScriptedBridgePeer(scripts: [
            [.respond(.handshake(self.receiptlessHandshake))],
            steps,
        ])
    }

    private static func projectedReceiptlessPeer(
        response: PeekabooBridgeResponse) throws -> ScriptedBridgePeer
    {
        try ScriptedBridgePeer(responses: [
            .handshake(self.projectedReceiptlessHandshake),
            response,
        ])
    }

    private static func negotiateReceiptless(_ client: PeekabooBridgeClient) async throws {
        _ = try await client.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.tests",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: self.receiptlessProtocolVersion)
    }

    private static func expectResponseLostFailure(_ failure: DesktopActionFailure) {
        #expect(failure.outcome.route == .bridge)
        #expect(failure.outcome.state == .indeterminate)
        #expect(failure.outcome.evidence == .responseLost)
        #expect(failure.outcome.retrySafety == .unsafe)
        #expect(failure.outcome.projection.requiresFreshObservation)
        #expect(failure.message.contains("indeterminate"))
        #expect(failure.message.contains("do not retry"))
        #expect(PendingSnapshotCleanupPolicy.shouldPreserveReservation(after: failure))
    }

    enum ReceiptlessProjectedMismatch: CaseIterable {
        case okWithRefusal
        case wrongResponseFamily
        case wrongRoute
        case wrongDelivery
        case wrongDispatchCount
        case browserProgressCountMismatch
        case missingHandlerTarget
        case contradictoryRequestPinnedTarget

        func fixture() throws -> (request: PeekabooBridgeRequest, response: PeekabooBridgeResponse) {
            let globalDelivery = DesktopActionOutcome.Delivery(
                mechanism: .globalEvents,
                mode: .foreground)
            let successfulGlobal = DesktopActionOutcome.dispatchedUnverified(
                route: .bridge,
                delivery: globalDelivery,
                evidence: .deliveryAccepted,
                unitCount: .one)
            switch self {
            case .okWithRefusal:
                let refusal = DesktopActionOutcome.refused(
                    route: .bridge,
                    reason: .permissionDenied)
                return (
                    PeekabooBridgeClientTransportOutcomeTests.moveMouseRequest,
                    .projectedAction(.init(response: .ok, outcome: refusal.projection)))
            case .wrongResponseFamily:
                return (
                    PeekabooBridgeClientTransportOutcomeTests.moveMouseRequest,
                    .projectedAction(.init(response: .bool(true), outcome: successfulGlobal.projection)))
            case .wrongRoute:
                let local = DesktopActionOutcome.dispatchedUnverified(
                    delivery: globalDelivery,
                    evidence: .deliveryAccepted,
                    unitCount: .one)
                return (
                    PeekabooBridgeClientTransportOutcomeTests.moveMouseRequest,
                    .projectedAction(.init(response: .ok, outcome: local.projection)))
            case .wrongDelivery:
                let wrongDelivery = DesktopActionOutcome.dispatchedUnverified(
                    route: .bridge,
                    delivery: .init(mechanism: .nativeFramework, mode: .background),
                    evidence: .deliveryAccepted,
                    unitCount: .one)
                return (
                    PeekabooBridgeClientTransportOutcomeTests.moveMouseRequest,
                    .projectedAction(.init(response: .ok, outcome: wrongDelivery.projection)))
            case .wrongDispatchCount:
                let twoUnits = try #require(DesktopActionOutcome.DispatchUnitCount(2))
                let wrongCount = DesktopActionOutcome.dispatchedUnverified(
                    route: .bridge,
                    delivery: globalDelivery,
                    evidence: .deliveryAccepted,
                    unitCount: twoUnits)
                return (
                    PeekabooBridgeClientTransportOutcomeTests.moveMouseRequest,
                    .projectedAction(.init(response: .ok, outcome: wrongCount.projection)))
            case .browserProgressCountMismatch:
                let receipt = PeekabooBridgeClientTransportOutcomeTests.browserConnectionReceipt
                let request = PeekabooBridgeRequest.browserExecute(.init(
                    calls: [.init(toolName: "fixture", arguments: [:])],
                    channel: receipt.channel,
                    expectedConnectionReceipt: receipt))
                let twoUnits = try #require(DesktopActionOutcome.DispatchUnitCount(2))
                let outcome = DesktopActionOutcome.dispatchedUnverified(
                    route: .bridge,
                    delivery: .init(mechanism: .browserProtocol, mode: .background),
                    evidence: .deliveryAccepted,
                    unitCount: twoUnits)
                let response = PeekabooBridgeBrowserToolResponse(
                    content: [],
                    isError: false,
                    meta: nil,
                    connectionReceipt: receipt,
                    completedCallCount: 1,
                    dispatchedCallCount: 2)
                return (
                    request,
                    .projectedAction(.init(
                        response: .browserToolResponse(response),
                        outcome: outcome.projection)))
            case .missingHandlerTarget:
                let request = PeekabooBridgeRequest.unhideApplication(.init(identifier: "TextEdit"))
                let outcome = DesktopActionOutcome.dispatchedUnverified(
                    route: .bridge,
                    delivery: .init(mechanism: .nativeFramework, mode: .background),
                    evidence: .deliveryAccepted,
                    unitCount: .one)
                return (request, .projectedAction(.init(response: .ok, outcome: outcome.projection)))
            case .contradictoryRequestPinnedTarget:
                let identity = WindowMutationIdentity(
                    windowID: 77,
                    ownerProcessIdentifier: 420,
                    ownerProcessStartIdentity: 9001,
                    capturedBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
                let request = PeekabooBridgeRequest.focusWindow(.init(
                    target: .windowId(identity.windowID),
                    expectedIdentity: identity))
                let failure = DesktopActionFailure.indeterminate(
                    route: .bridge,
                    delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                    evidence: .completionUnknown,
                    unitCount: .one,
                    message: "Focus completion is uncertain")
                    .attributed(to: .init(
                        processIdentifier: identity.ownerProcessIdentifier,
                        processStartIdentity: identity.ownerProcessStartIdentity,
                        windowID: identity.windowID + 1))
                let envelope = PeekabooBridgeErrorEnvelope(code: .internalError, actionFailure: failure)
                return (
                    request,
                    .projectedAction(.init(
                        response: .error(envelope),
                        outcome: failure.outcome.projection)))
            }
        }
    }

    private static func connectRawClient(to socketPath: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout.size(ofValue: address))
            let copied = socketPath.withCString { source in
                strlcpy(&address.sun_path.0, source, MemoryLayout.size(ofValue: address.sun_path))
            }
            guard copied < MemoryLayout.size(ofValue: address.sun_path) else {
                throw POSIXError(.ENAMETOOLONG)
            }
            let length = socklen_t(MemoryLayout.size(ofValue: address))
            let result = withUnsafePointer(to: &address) { pointer in
                Darwin.connect(descriptor, UnsafePointer<sockaddr>(OpaquePointer(pointer)), length)
            }
            guard result == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func waitUntilAccepted(_ peer: ScriptedBridgePeer) async -> Bool {
        for _ in 0..<200 {
            if await peer.acceptedConnectionCount == 1 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private static func waitUntilSocketRemoved(_ socketPath: String) async -> Bool {
        for _ in 0..<200 {
            if !FileManager.default.fileExists(atPath: socketPath) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}
