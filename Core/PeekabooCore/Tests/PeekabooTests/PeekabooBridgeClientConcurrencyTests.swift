import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeClientConcurrencyTests {
    @Test
    func `initial negotiation reentrancy refuses an unreceipted request`() async throws {
        let root = Self.temporaryRoot("initial-negotiation")
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let clientInstanceID = UUID()
        let session = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let peer = try ConcurrentGatedBridgePeer()
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            requestTimeoutSec: 10,
            operationClientInstanceID: clientInstanceID)

        do {
            let negotiation = Task {
                try await client.handshake(client: Self.clientIdentity)
            }
            let handshakeRequest = try await peer.nextRequest()
            try Self.requireHandshake(handshakeRequest)

            do {
                _ = try await client.send(.permissionsStatus)
                Issue.record("A request escaped while its first receipt session was still negotiating")
            } catch let error as PeekabooBridgeClientOperationSessionError {
                #expect(error == .negotiationInProgress)
            }
            #expect(await peer.acceptedConnectionCount == 1)

            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: session.attestation)),
                to: handshakeRequest)
            let negotiated = try await negotiation.value
            #expect(negotiated.operationSessionAttestation?.sessionID == session.attestation.sessionID)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test
    func `a late older legacy handshake cannot overwrite a newer signed epoch`() async throws {
        let root = Self.temporaryRoot("handshake-epoch")
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path,
            maximumSessionCount: 8,
            maximumActiveSessionCountPerPeer: 8,
            retainedRetiredSessionCount: 2)
        let clientInstanceID = UUID()
        let newerSession = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let peer = try ConcurrentGatedBridgePeer()
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            requestTimeoutSec: 10,
            operationClientInstanceID: clientInstanceID)

        do {
            let older = Task {
                try await client.handshake(client: Self.clientIdentity)
            }
            let olderRequest = try await peer.nextRequest()
            try Self.requireHandshake(olderRequest)

            let newer = Task {
                try await client.handshake(client: Self.clientIdentity)
            }
            let newerRequest = try await peer.nextRequest()
            try Self.requireHandshake(newerRequest)

            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: newerSession.attestation)),
                to: newerRequest)
            #expect(try await newer.value.operationSessionAttestation?.sessionID == newerSession.attestation.sessionID)

            try await peer.respond(
                .handshake(Self.legacyHandshake()),
                to: olderRequest)
            do {
                _ = try await older.value
                Issue.record("The superseded handshake unexpectedly committed")
            } catch let error as PeekabooBridgeClientOperationSessionError {
                #expect(error == .superseded)
            }

            let reservation = try #require(try await client.reserveOperationSession())
            #expect(reservation.sessionAttestation.sessionID == newerSession.attestation.sessionID)
            #expect(reservation.sequence.value == 0)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test
    func `a late older signed handshake cannot overwrite a newer legacy epoch`() async throws {
        let root = Self.temporaryRoot("handshake-epoch-legacy-wins")
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let clientInstanceID = UUID()
        let olderSession = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let peer = try ConcurrentGatedBridgePeer()
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            requestTimeoutSec: 10,
            operationClientInstanceID: clientInstanceID)

        do {
            let older = Task {
                try await client.handshake(client: Self.clientIdentity)
            }
            let olderRequest = try await peer.nextRequest()
            try Self.requireHandshake(olderRequest)

            let newer = Task {
                try await client.handshake(client: Self.clientIdentity)
            }
            let newerRequest = try await peer.nextRequest()
            try Self.requireHandshake(newerRequest)

            try await peer.respond(.handshake(Self.legacyHandshake()), to: newerRequest)
            let latest = try await newer.value
            #expect(latest.negotiatedVersion < PeekabooBridgeConstants.attestedOperationReceiptVersion)
            #expect(latest.operationSessionAttestation == nil)

            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: olderSession.attestation)),
                to: olderRequest)
            do {
                _ = try await older.value
                Issue.record("The superseded signed handshake unexpectedly committed over the legacy epoch")
            } catch let error as PeekabooBridgeClientOperationSessionError {
                #expect(error == .superseded)
            }

            #expect(try await client.reserveOperationSession()?.requestID == nil)
            #expect(await peer.acceptedConnectionCount == 2)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test
    func `a late old-session receipt cannot regress the successor budget or cache`() async throws {
        let root = Self.temporaryRoot("late-receipt")
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path,
            maximumClaimCount: 4,
            maximumSessionCount: 8,
            maximumActiveSessionCountPerPeer: 4,
            retainedRetiredSessionCount: 2)
        let clientInstanceID = UUID()
        let oldSession = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let peer = try ConcurrentGatedBridgePeer()
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            requestTimeoutSec: 10,
            operationClientInstanceID: clientInstanceID)

        do {
            let initialHandshake = Task { try await client.handshake(client: Self.clientIdentity) }
            let initialHandshakeRequest = try await peer.nextRequest()
            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: oldSession.attestation)),
                to: initialHandshakeRequest)
            _ = try await initialHandshake.value

            let oldCall = Task { try await client.send(.permissionsStatus) }
            let oldWireRequest = try await peer.nextRequest()
            let oldClaim = try await Self.acceptedClaim(
                oldWireRequest,
                authority: authority,
                peer: oldSession.peer)

            let successor = try await OperationReceiptSessionFixture.make(
                authority: authority,
                clientInstanceID: clientInstanceID,
                peer: oldSession.peer,
                replacing: oldSession.attestation.sessionID)
            let rolloverHandshake = Task { try await client.handshake(client: Self.clientIdentity) }
            let rolloverHandshakeRequest = try await peer.nextRequest()
            let rolloverPayload = try Self.requireHandshake(rolloverHandshakeRequest)
            #expect(rolloverPayload.replacingOperationSessionID == oldSession.attestation.sessionID)
            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: successor.attestation)),
                to: rolloverHandshakeRequest)
            _ = try await rolloverHandshake.value

            let successorCall = Task { try await client.send(.permissionsStatus) }
            let successorWireRequest = try await peer.nextRequest()
            let successorClaim = try await Self.acceptedClaim(
                successorWireRequest,
                authority: authority,
                peer: successor.peer)
            let successorResponse = try await Self.receiptedPermissionsResponse(
                authority: authority,
                session: successor,
                claim: successorClaim)
            try await peer.respond(successorResponse.wireResponse, to: successorWireRequest)
            _ = try await successorCall.value
            let currentReceipt = try #require(await client.lastOperationReceipt())
            #expect(currentReceipt.payload.requestID == successorResponse.receipt.payload.requestID)

            let oldResponse = try await Self.receiptedPermissionsResponse(
                authority: authority,
                session: oldSession,
                claim: oldClaim)
            try await peer.respond(oldResponse.wireResponse, to: oldWireRequest)
            _ = try await oldCall.value

            let receiptAfterLateCompletion = try #require(await client.lastOperationReceipt())
            #expect(receiptAfterLateCompletion.payload.requestID == successorResponse.receipt.payload.requestID)
            #expect(receiptAfterLateCompletion.payload.requestID != oldResponse.receipt.payload.requestID)
            let next = try #require(try await client.reserveOperationSession())
            #expect(next.sessionAttestation.sessionID == successor.attestation.sessionID)
            #expect(next.sequence.value == 1)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test
    func `renewal timeout and cancellation are per waiter while a survivor succeeds`() async throws {
        let root = Self.temporaryRoot("renewal-waiters")
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path,
            maximumClaimCount: 2,
            maximumSessionCount: 8,
            maximumActiveSessionCountPerPeer: 4,
            retainedRetiredSessionCount: 2)
        let clientInstanceID = UUID()
        let oldSession = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let peer = try ConcurrentGatedBridgePeer()
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            requestTimeoutSec: 10,
            operationClientInstanceID: clientInstanceID)

        do {
            let initialHandshake = Task { try await client.handshake(client: Self.clientIdentity) }
            let initialRequest = try await peer.nextRequest()
            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: oldSession.attestation)),
                to: initialRequest)
            _ = try await initialHandshake.value

            let firstReservation = try #require(try await client.reserveOperationSession())
            #expect(firstReservation.sequence.value == 0)
            #expect(await client.operationSessionRequiresRenewal())

            let survivor = Task {
                try await client.renewOperationSession(
                    replacingSessionID: oldSession.attestation.sessionID,
                    overallTimeoutSec: 10)
            }
            let renewalRequest = try await peer.nextRequest()
            let renewalPayload = try Self.requireHandshake(renewalRequest)
            #expect(renewalPayload.replacingOperationSessionID == oldSession.attestation.sessionID)

            do {
                _ = try await client.renewOperationSession(
                    replacingSessionID: oldSession.attestation.sessionID,
                    overallTimeoutSec: 0)
                Issue.record("The zero-budget renewal waiter unexpectedly survived")
            } catch let error as POSIXError {
                #expect(error.code == .ETIMEDOUT)
            }

            let cancellationGate = TestContinuationGate()
            let cancelledWaiter = Task {
                await cancellationGate.wait()
                return try await client.renewOperationSession(
                    replacingSessionID: oldSession.attestation.sessionID,
                    overallTimeoutSec: 10)
            }
            cancelledWaiter.cancel()
            await cancellationGate.open()
            do {
                _ = try await cancelledWaiter.value
                Issue.record("The cancelled renewal waiter unexpectedly survived")
            } catch is CancellationError {
                // Expected. Its cancellation must not propagate to the shared renewal task.
            }

            let successor = try await OperationReceiptSessionFixture.make(
                authority: authority,
                clientInstanceID: clientInstanceID,
                peer: oldSession.peer,
                replacing: oldSession.attestation.sessionID)
            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: successor.attestation)),
                to: renewalRequest)
            let installed = try await survivor.value
            #expect(installed.sessionID == successor.attestation.sessionID)
            #expect(await peer.acceptedConnectionCount == 2)

            let reservation = try #require(try await client.reserveOperationSession())
            #expect(reservation.sessionAttestation.sessionID == successor.attestation.sessionID)
            #expect(reservation.sequence.value == 0)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test
    func `signed rollover winning a renewal race releases the handshake token`() async throws {
        let root = Self.temporaryRoot("rollover-wins-renewal")
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path,
            maximumClaimCount: 2,
            maximumSessionCount: 8,
            maximumActiveSessionCountPerPeer: 4,
            retainedRetiredSessionCount: 2)
        let clientInstanceID = UUID()
        let oldSession = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let peer = try ConcurrentGatedBridgePeer()
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            requestTimeoutSec: 10,
            operationClientInstanceID: clientInstanceID)

        do {
            let initialHandshake = Task { try await client.handshake(client: Self.clientIdentity) }
            let initialRequest = try await peer.nextRequest()
            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: oldSession.attestation)),
                to: initialRequest)
            _ = try await initialHandshake.value

            let predecessorReservation = try #require(try await client.reserveOperationSession())
            #expect(await client.operationSessionRequiresRenewal())
            let renewal = Task {
                try await client.renewOperationSession(
                    replacingSessionID: oldSession.attestation.sessionID,
                    overallTimeoutSec: 10)
            }
            let renewalRequest = try await peer.nextRequest()
            let renewalPayload = try Self.requireHandshake(renewalRequest)
            #expect(renewalPayload.replacingOperationSessionID == oldSession.attestation.sessionID)

            let successor = try await OperationReceiptSessionFixture.make(
                authority: authority,
                clientInstanceID: clientInstanceID,
                peer: oldSession.peer,
                replacing: oldSession.attestation.sessionID)
            _ = try await client.installOperationSession(
                successor.attestation,
                listenerAttestation: authority.attestation,
                replacingSessionID: oldSession.attestation.sessionID,
                expectedEpoch: predecessorReservation.epoch)
            #expect(try await renewal.value.sessionID == successor.attestation.sessionID)

            let successorReservation = try #require(try await client.reserveOperationSession())
            #expect(successorReservation.sessionAttestation.sessionID == successor.attestation.sessionID)
            do {
                _ = try await client.reserveOperationSession()
                Issue.record("Expected the exhausted successor to require another renewal")
            } catch let error as PeekabooBridgeClientOperationSessionError {
                guard case let .renewalRequired(sessionID, _) = error else {
                    Issue.record("Expected renewalRequired after the race, got \(error)")
                    throw error
                }
                #expect(sessionID == successor.attestation.sessionID)
            }

            let nextRenewal = Task {
                try await client.renewOperationSession(
                    replacingSessionID: successor.attestation.sessionID,
                    overallTimeoutSec: 10)
            }
            let nextRenewalRequest = try await peer.nextRequest()
            let nextRenewalPayload = try Self.requireHandshake(nextRenewalRequest)
            #expect(nextRenewalPayload.replacingOperationSessionID == successor.attestation.sessionID)
            let secondSuccessor = try await OperationReceiptSessionFixture.make(
                authority: authority,
                clientInstanceID: clientInstanceID,
                peer: oldSession.peer,
                replacing: successor.attestation.sessionID)
            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: secondSuccessor.attestation)),
                to: nextRenewalRequest)
            #expect(try await nextRenewal.value.sessionID == secondSuccessor.attestation.sessionID)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test
    func `signed unavailable rollover refuses once and invalidates the old session`() async throws {
        let root = Self.temporaryRoot("rollover-unavailable")
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path,
            maximumClaimCount: 3,
            maximumSessionCount: 2,
            maximumActiveSessionCountPerPeer: 2,
            retainedRetiredSessionCount: 1)
        let clientInstanceID = UUID()
        let oldSession = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let peer = try ConcurrentGatedBridgePeer()
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            requestTimeoutSec: 10,
            operationClientInstanceID: clientInstanceID)

        do {
            let initialHandshake = Task { try await client.handshake(client: Self.clientIdentity) }
            let initialRequest = try await peer.nextRequest()
            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: oldSession.attestation)),
                to: initialRequest)
            _ = try await initialHandshake.value

            // Keep the retired predecessor alive so bounded-state pressure cannot prune it before it signs the
            // second request's refusal.
            let inFlightOldCall = Task { try await client.send(.permissionsStatus) }
            let inFlightOldRequest = try await peer.nextRequest()
            let inFlightOldClaim = try await Self.acceptedClaim(
                inFlightOldRequest,
                authority: authority,
                peer: oldSession.peer)
            try authority.retireSession(
                oldSession.attestation.sessionID,
                clientInstanceID: clientInstanceID,
                peer: oldSession.peer)
            _ = try await authority.createSession(
                clientInstanceID: UUID(),
                peer: oldSession.peer)

            let refusedCall = Task {
                try await client.sendExpectOK(.requestPostEventPermission)
            }
            let refusedRequest = try await peer.nextRequest()
            guard case let .attestedOperation(refusedPayload) = try refusedRequest.decode() else {
                throw ClientConcurrencyFixtureError.expectedAttestedOperation
            }
            guard case let .rolloverRequired(refusal) = try await authority.claim(
                refusedPayload,
                peer: oldSession.peer)
            else {
                throw ClientConcurrencyFixtureError.expectedRolloverRefusal
            }
            #expect(refusal.payload.disposition == .sessionRolloverUnavailable)
            #expect(refusal.payload.successorSessionAttestation == nil)
            try await peer.respond(.operationSessionRollover(refusal), to: refusedRequest)

            do {
                try await refusedCall.value
                Issue.record("The unavailable rollover unexpectedly executed or retried")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .refused)
                #expect(failure.outcome.refusalReason == .transportSessionUnavailable)
                #expect(failure.outcome.dispatchState == .none)
                #expect(failure.outcome.retrySafety == .safe)
                #expect(failure.outcome.escalation == .reconnectSession)
            }
            #expect(await peer.acceptedConnectionCount == 3)

            do {
                _ = try await client.reserveOperationSession()
                Issue.record("The unavailable rollover left the predecessor session reusable")
            } catch let error as PeekabooBridgeClientOperationSessionError {
                guard case let .renewalRequired(sessionID, _) = error else {
                    Issue.record("Expected renewalRequired, got \(error)")
                    throw error
                }
                #expect(sessionID == oldSession.attestation.sessionID)
            }

            let oldResponse = try await Self.receiptedPermissionsResponse(
                authority: authority,
                session: oldSession,
                claim: inFlightOldClaim)
            try await peer.respond(oldResponse.wireResponse, to: inFlightOldRequest)
            _ = try await inFlightOldCall.value
            #expect(await client.lastOperationReceipt() == nil)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }
}

extension PeekabooBridgeClientConcurrencyTests {
    @Test
    func `concurrent sends chain renewals when one successor fills before the other waiter reserves`() async throws {
        let root = Self.temporaryRoot("concurrent-successor-exhaustion")
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path,
            maximumClaimCount: 2,
            maximumSessionCount: 8,
            maximumActiveSessionCountPerPeer: 4,
            retainedRetiredSessionCount: 2)
        let clientInstanceID = UUID()
        let predecessor = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let peer = try ConcurrentGatedBridgePeer()
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            requestTimeoutSec: 10,
            operationClientInstanceID: clientInstanceID)

        do {
            let initialHandshake = Task { try await client.handshake(client: Self.clientIdentity) }
            let initialRequest = try await peer.nextRequest()
            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: predecessor.attestation)),
                to: initialRequest)
            _ = try await initialHandshake.value

            let predecessorReservation = try #require(try await client.reserveOperationSession())
            #expect(predecessorReservation.sequence.value == 0)
            #expect(await client.operationSessionRequiresRenewal())

            let firstCall = Task { try await client.send(.permissionsStatus) }
            let secondCall = Task { try await client.send(.permissionsStatus) }
            let firstRenewalRequest = try await peer.nextRequest()
            let firstRenewalPayload = try Self.requireHandshake(firstRenewalRequest)
            #expect(firstRenewalPayload.replacingOperationSessionID == predecessor.attestation.sessionID)
            let firstSuccessor = try await OperationReceiptSessionFixture.make(
                authority: authority,
                clientInstanceID: clientInstanceID,
                peer: predecessor.peer,
                replacing: predecessor.attestation.sessionID)
            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: firstSuccessor.attestation)),
                to: firstRenewalRequest)

            // Both waiters resume from the same renewal. One reserves sequence zero; the other must observe the
            // protected final slot and chain into another shared renewal instead of leaking `renewalRequired`.
            let firstPostRenewalRequest = try await peer.nextRequest()
            let secondPostRenewalRequest = try await peer.nextRequest()
            var operationOnFirstSuccessor: ConcurrentGatedBridgePeer.Request?
            var secondRenewalRequest: ConcurrentGatedBridgePeer.Request?
            for request in [firstPostRenewalRequest, secondPostRenewalRequest] {
                switch try request.decode() {
                case let .attestedOperation(payload):
                    #expect(payload.sessionID == firstSuccessor.attestation.sessionID)
                    operationOnFirstSuccessor = request
                case let .handshake(payload):
                    #expect(payload.replacingOperationSessionID == firstSuccessor.attestation.sessionID)
                    secondRenewalRequest = request
                default:
                    Issue.record("Expected one successor operation and one chained renewal")
                }
            }

            // Claim the first successor operation before retiring that session with the chained renewal.
            let firstSuccessorRequest = try #require(operationOnFirstSuccessor)
            let firstSuccessorClaim = try await Self.acceptedClaim(
                firstSuccessorRequest,
                authority: authority,
                peer: firstSuccessor.peer)
            let firstSuccessorResponse = try await Self.receiptedPermissionsResponse(
                authority: authority,
                session: firstSuccessor,
                claim: firstSuccessorClaim)
            try await peer.respond(firstSuccessorResponse.wireResponse, to: firstSuccessorRequest)

            let chainedRenewalRequest = try #require(secondRenewalRequest)
            let secondSuccessor = try await OperationReceiptSessionFixture.make(
                authority: authority,
                clientInstanceID: clientInstanceID,
                peer: predecessor.peer,
                replacing: firstSuccessor.attestation.sessionID)
            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: secondSuccessor.attestation)),
                to: chainedRenewalRequest)

            let secondSuccessorRequest = try await peer.nextRequest()
            let secondSuccessorClaim = try await Self.acceptedClaim(
                secondSuccessorRequest,
                authority: authority,
                peer: secondSuccessor.peer)
            let secondSuccessorResponse = try await Self.receiptedPermissionsResponse(
                authority: authority,
                session: secondSuccessor,
                claim: secondSuccessorClaim)
            try await peer.respond(secondSuccessorResponse.wireResponse, to: secondSuccessorRequest)

            guard case .permissionsStatus = try await firstCall.value else {
                Issue.record("Expected first concurrent permissions response")
                await peer.stop()
                return
            }
            guard case .permissionsStatus = try await secondCall.value else {
                Issue.record("Expected second concurrent permissions response")
                await peer.stop()
                return
            }
            #expect(await peer.acceptedConnectionCount == 5)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test
    func `explicit handshake accepts an exact successor installed first by signed rollover without resetting it`() async
        throws
    {
        let root = Self.temporaryRoot("explicit-handshake-rollover-race")
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path,
            maximumClaimCount: 4,
            maximumSessionCount: 8,
            maximumActiveSessionCountPerPeer: 4,
            retainedRetiredSessionCount: 2)
        let clientInstanceID = UUID()
        let predecessor = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let peer = try ConcurrentGatedBridgePeer()
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            requestTimeoutSec: 10,
            operationClientInstanceID: clientInstanceID)

        do {
            let initialHandshake = Task { try await client.handshake(client: Self.clientIdentity) }
            let initialRequest = try await peer.nextRequest()
            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: predecessor.attestation)),
                to: initialRequest)
            _ = try await initialHandshake.value

            let predecessorCall = Task { try await client.send(.permissionsStatus) }
            let predecessorRequest = try await peer.nextRequest()
            let explicitHandshake = Task { try await client.handshake(client: Self.clientIdentity) }
            let explicitHandshakeRequest = try await peer.nextRequest()
            let explicitPayload = try Self.requireHandshake(explicitHandshakeRequest)
            #expect(explicitPayload.replacingOperationSessionID == predecessor.attestation.sessionID)

            let successor = try await OperationReceiptSessionFixture.make(
                authority: authority,
                clientInstanceID: clientInstanceID,
                peer: predecessor.peer,
                replacing: predecessor.attestation.sessionID)
            guard case let .attestedOperation(predecessorPayload) = try predecessorRequest.decode() else {
                throw ClientConcurrencyFixtureError.expectedAttestedOperation
            }
            guard case let .rolloverRequired(refusal) = try await authority.claim(
                predecessorPayload,
                peer: predecessor.peer)
            else {
                throw ClientConcurrencyFixtureError.expectedRolloverRefusal
            }
            try await peer.respond(.operationSessionRollover(refusal), to: predecessorRequest)

            let successorRequest = try await peer.nextRequest()
            let successorClaim = try await Self.acceptedClaim(
                successorRequest,
                authority: authority,
                peer: successor.peer)
            let successorResponse = try await Self.receiptedPermissionsResponse(
                authority: authority,
                session: successor,
                claim: successorClaim)
            try await peer.respond(successorResponse.wireResponse, to: successorRequest)
            guard case .permissionsStatus = try await predecessorCall.value else {
                Issue.record("Expected the rollover-backed predecessor call to complete")
                await peer.stop()
                return
            }
            let receiptBeforeHandshake = try #require(await client.lastOperationReceipt())

            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: successor.attestation)),
                to: explicitHandshakeRequest)
            let completedHandshake = try await explicitHandshake.value
            #expect(completedHandshake.operationSessionAttestation == successor.attestation)
            #expect(await client.lastOperationReceipt() == receiptBeforeHandshake)

            let nextReservation = try #require(try await client.reserveOperationSession())
            #expect(nextReservation.sessionAttestation == successor.attestation)
            #expect(nextReservation.sequence.value == 1)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test
    func `definitive renewal rejection requires explicit recovery while retaining the predecessor`() async throws {
        let root = Self.temporaryRoot("renewal-rejection-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path,
            maximumClaimCount: 2,
            maximumSessionCount: 8,
            maximumActiveSessionCountPerPeer: 4,
            retainedRetiredSessionCount: 2)
        let clientInstanceID = UUID()
        let predecessor = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let peer = try ConcurrentGatedBridgePeer()
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            requestTimeoutSec: 10,
            operationClientInstanceID: clientInstanceID)

        do {
            let initialHandshake = Task { try await client.handshake(client: Self.clientIdentity) }
            let initialRequest = try await peer.nextRequest()
            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: predecessor.attestation)),
                to: initialRequest)
            _ = try await initialHandshake.value
            _ = try #require(try await client.reserveOperationSession())

            let failedCall = Task { try await client.send(.permissionsStatus) }
            let rejectedRenewalRequest = try await peer.nextRequest()
            let rejectedPayload = try Self.requireHandshake(rejectedRenewalRequest)
            #expect(rejectedPayload.replacingOperationSessionID == predecessor.attestation.sessionID)
            try await peer.respond(
                .error(.init(
                    code: .invalidRequest,
                    message: "The predecessor is no longer owned by this listener",
                    context: "bridge_operation_session:handshake")),
                to: rejectedRenewalRequest)
            do {
                _ = try await failedCall.value
                Issue.record("Expected definitive renewal rejection")
            } catch let envelope as PeekabooBridgeErrorEnvelope {
                #expect(envelope.code == .invalidRequest)
            }

            do {
                _ = try await client.reserveOperationSession()
                Issue.record("Expected a rejected renewal to require an explicit cold handshake")
            } catch let error as PeekabooBridgeClientOperationSessionError {
                #expect(error == .handshakeRequired)
            }

            let recovery = Task { try await client.handshake(client: Self.clientIdentity) }
            let recoveryRequest = try await peer.nextRequest()
            let recoveryPayload = try Self.requireHandshake(recoveryRequest)
            #expect(recoveryPayload.replacingOperationSessionID == predecessor.attestation.sessionID)
            let successor = try await OperationReceiptSessionFixture.make(
                authority: authority,
                clientInstanceID: clientInstanceID,
                peer: predecessor.peer,
                replacing: predecessor.attestation.sessionID)
            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: successor.attestation)),
                to: recoveryRequest)
            #expect(try await recovery.value.operationSessionAttestation == successor.attestation)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test
    func `kernel peer replacement requires explicit recovery without losing predecessor identity`() async throws {
        let root = Self.temporaryRoot("kernel-peer-replacement")
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path,
            maximumClaimCount: 4,
            maximumSessionCount: 8,
            maximumActiveSessionCountPerPeer: 4,
            retainedRetiredSessionCount: 2)
        let clientInstanceID = UUID()
        let predecessor = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let peer = try ConcurrentGatedBridgePeer()
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            requestTimeoutSec: 10,
            operationClientInstanceID: clientInstanceID)

        do {
            let initialHandshake = Task { try await client.handshake(client: Self.clientIdentity) }
            let initialRequest = try await peer.nextRequest()
            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: predecessor.attestation)),
                to: initialRequest)
            _ = try await initialHandshake.value
            let reservation = try #require(try await client.reserveOperationSession())

            await client.recordOperationSessionTransportFailure(
                PeekabooBridgeOperationReceiptError.peerIdentityMismatch,
                sessionID: reservation.sessionAttestation.sessionID,
                epoch: reservation.epoch)
            do {
                _ = try await client.reserveOperationSession()
                Issue.record("Expected a kernel peer replacement to require an explicit handshake")
            } catch let error as PeekabooBridgeClientOperationSessionError {
                #expect(error == .handshakeRequired)
            }

            let recovery = Task { try await client.handshake(client: Self.clientIdentity) }
            let recoveryRequest = try await peer.nextRequest()
            let recoveryPayload = try Self.requireHandshake(recoveryRequest)
            #expect(recoveryPayload.replacingOperationSessionID == predecessor.attestation.sessionID)
            let successor = try await OperationReceiptSessionFixture.make(
                authority: authority,
                clientInstanceID: clientInstanceID,
                peer: predecessor.peer,
                replacing: predecessor.attestation.sessionID)
            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: successor.attestation)),
                to: recoveryRequest)
            #expect(try await recovery.value.operationSessionAttestation == successor.attestation)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test
    func `automatic renewal downgrade requires an explicit legacy handshake`() async throws {
        let root = Self.temporaryRoot("renewal-legacy-downgrade")
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path,
            maximumClaimCount: 2,
            maximumSessionCount: 8,
            maximumActiveSessionCountPerPeer: 4,
            retainedRetiredSessionCount: 2)
        let clientInstanceID = UUID()
        let predecessor = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let peer = try ConcurrentGatedBridgePeer()
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            requestTimeoutSec: 10,
            operationClientInstanceID: clientInstanceID)

        do {
            let initialHandshake = Task { try await client.handshake(client: Self.clientIdentity) }
            let initialRequest = try await peer.nextRequest()
            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: predecessor.attestation)),
                to: initialRequest)
            _ = try await initialHandshake.value
            _ = try #require(try await client.reserveOperationSession())

            let failedCall = Task { try await client.send(.permissionsStatus) }
            let currentRenewalRequest = try await peer.nextRequest()
            let currentRenewalPayload = try Self.requireHandshake(currentRenewalRequest)
            #expect(currentRenewalPayload.protocolVersion == PeekabooBridgeConstants.protocolVersion)
            #expect(currentRenewalPayload.replacingOperationSessionID == predecessor.attestation.sessionID)
            try await peer.respond(
                .error(.init(code: .versionMismatch, message: "Current protocol is unavailable")),
                to: currentRenewalRequest)

            for minor in stride(
                from: PeekabooBridgeConstants.protocolVersion.minor - 1,
                through: PeekabooBridgeConstants.attestedOperationReceiptVersion.minor,
                by: -1)
            {
                let fallbackRenewalRequest = try await peer.nextRequest()
                let fallbackRenewalPayload = try Self.requireHandshake(fallbackRenewalRequest)
                let expectedVersion = PeekabooBridgeProtocolVersion(
                    major: PeekabooBridgeConstants.protocolVersion.major,
                    minor: minor)
                #expect(fallbackRenewalPayload.protocolVersion == expectedVersion)
                #expect(fallbackRenewalPayload.replacingOperationSessionID == predecessor.attestation.sessionID)
                try await peer.respond(
                    .error(.init(
                        code: .versionMismatch,
                        message: "Protocol \(expectedVersion.major).\(expectedVersion.minor) is unavailable")),
                    to: fallbackRenewalRequest)
            }

            let legacyRenewalRequest = try await peer.nextRequest()
            let legacyRenewalPayload = try Self.requireHandshake(legacyRenewalRequest)
            #expect(legacyRenewalPayload.protocolVersion < PeekabooBridgeConstants.attestedOperationReceiptVersion)
            #expect(legacyRenewalPayload.replacingOperationSessionID == predecessor.attestation.sessionID)
            try await peer.respond(.handshake(Self.legacyHandshake()), to: legacyRenewalRequest)
            do {
                _ = try await failedCall.value
                Issue.record("Automatic renewal unexpectedly downgraded and dispatched a receiptless request")
            } catch let error as PeekabooBridgeClientOperationSessionError {
                #expect(error == .handshakeRequired)
            }

            do {
                _ = try await client.reserveOperationSession()
                Issue.record("Legacy renewal fallback did not require an explicit handshake")
            } catch let error as PeekabooBridgeClientOperationSessionError {
                #expect(error == .handshakeRequired)
            }

            let explicitLegacyHandshake = Task {
                try await client.handshake(
                    client: Self.clientIdentity,
                    protocolVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 28))
            }
            let explicitLegacyRequest = try await peer.nextRequest()
            let explicitLegacyPayload = try Self.requireHandshake(explicitLegacyRequest)
            #expect(explicitLegacyPayload.replacingOperationSessionID == predecessor.attestation.sessionID)
            try await peer.respond(.handshake(Self.legacyHandshake()), to: explicitLegacyRequest)
            let explicitLegacyResponse = try await explicitLegacyHandshake.value
            #expect(explicitLegacyResponse.negotiatedVersion < PeekabooBridgeConstants.attestedOperationReceiptVersion)
            #expect(try await client.reserveOperationSession() == nil)

            let rawCall = Task { try await client.send(.permissionsStatus) }
            let rawRequest = try await peer.nextRequest()
            guard case .permissionsStatus = try rawRequest.decode() else {
                Issue.record("Explicit legacy handshake did not restore raw 1.28 request semantics")
                await peer.stop()
                return
            }
            try await peer.respond(
                .permissionsStatus(.init(screenRecording: true, accessibility: true, postEvent: true)),
                to: rawRequest)
            guard case .permissionsStatus = try await rawCall.value else {
                Issue.record("Expected raw legacy permissions response")
                await peer.stop()
                return
            }
            #expect(await client.lastOperationReceipt() == nil)
            let automaticAttestedAttemptCount = PeekabooBridgeConstants.protocolVersion.minor -
                PeekabooBridgeConstants.attestedOperationReceiptVersion.minor + 1
            let expectedConnectionCount = 1 + automaticAttestedAttemptCount + 1 + 1 + 1
            #expect(await peer.acceptedConnectionCount == expectedConnectionCount)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test
    func `hide mutation refuses when a legacy handshake wins during application resolution`() async throws {
        let root = Self.temporaryRoot("hide-target-downgrade")
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let clientInstanceID = UUID()
        let session = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let peer = try ConcurrentGatedBridgePeer()
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            requestTimeoutSec: 10,
            operationClientInstanceID: clientInstanceID)

        do {
            let initialHandshake = Task { try await client.handshake(client: Self.clientIdentity) }
            let initialRequest = try await peer.nextRequest()
            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: session.attestation)),
                to: initialRequest)
            _ = try await initialHandshake.value

            let hideMutation = Task {
                try await client.hideApplicationTargetedResult(identifier: "Fixture")
            }
            let heldFindRequest = try await peer.nextRequest()
            let findClaim = try await Self.acceptedClaim(
                heldFindRequest,
                authority: authority,
                peer: session.peer)
            guard case let .findApplication(findRequest) = findClaim.request.request else {
                Issue.record("Expected application resolution before hide transport")
                await peer.stop()
                return
            }
            #expect(findRequest.identifier == "Fixture")

            let legacyHandshake = Task {
                try await client.handshake(
                    client: Self.clientIdentity,
                    protocolVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 28))
            }
            let legacyHandshakeRequest = try await peer.nextRequest()
            let legacyHandshakePayload = try Self.requireHandshake(legacyHandshakeRequest)
            #expect(legacyHandshakePayload.replacingOperationSessionID == session.attestation.sessionID)
            try await peer.respond(.handshake(Self.legacyHandshake()), to: legacyHandshakeRequest)
            #expect(try await legacyHandshake.value.negotiatedVersion <
                PeekabooBridgeConstants.attestedOperationReceiptVersion)

            let identity = ApplicationProcessIdentity(
                processIdentifier: 42,
                processStartIdentity: 10042)
            let selectorProof = SelectorResolutionProof(
                scope: .application,
                normalizedSelector: ApplicationIdentifierMatcher.normalized("Fixture"),
                matchKind: .exactName,
                matchPrecedence: SelectorResolutionProof.MatchKind.exactName.precedence,
                selectedProcessIdentity: identity,
                candidateSetSHA256: String(repeating: "a", count: 64),
                candidateCount: 1,
                winningCandidateCount: 1,
                hasWinningTie: false)
            let applicationResponse = PeekabooBridgeResponse.application(.init(
                processIdentifier: identity.processIdentifier,
                processStartIdentity: identity.processStartIdentity,
                bundleIdentifier: "dev.peekaboo.fixture",
                name: "Fixture",
                selectorResolutionProofs: [selectorProof]))
            let receiptedApplication = try await Self.receiptedResponse(
                authority: authority,
                claim: findClaim,
                response: applicationResponse,
                target: .process(identity))
            try await peer.respond(receiptedApplication.wireResponse, to: heldFindRequest)

            do {
                _ = try await hideMutation.value
                Issue.record("The exact hide mutation escaped without an operation receipt")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .refused)
                #expect(failure.outcome.refusalReason == .transportSessionUnavailable)
                #expect(failure.outcome.dispatchState == .none)
                #expect(failure.outcome.retrySafety == .safe)
            }
            #expect(await peer.acceptedConnectionCount == 3)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test
    func `browser mutation refuses when a legacy handshake wins during target inspection`() async throws {
        let root = Self.temporaryRoot("browser-target-downgrade")
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let clientInstanceID = UUID()
        let session = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let peer = try ConcurrentGatedBridgePeer()
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            requestTimeoutSec: 10,
            operationClientInstanceID: clientInstanceID)

        do {
            let initialHandshake = Task { try await client.handshake(client: Self.clientIdentity) }
            let initialRequest = try await peer.nextRequest()
            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: session.attestation)),
                to: initialRequest)
            _ = try await initialHandshake.value

            let browserMutation = Task {
                try await client.browserExecuteResult(.init(
                    toolName: "click",
                    arguments: ["uid": .string("7_1")],
                    channel: "stable"))
            }
            let heldStatusRequest = try await peer.nextRequest()
            let statusClaim = try await Self.acceptedClaim(
                heldStatusRequest,
                authority: authority,
                peer: session.peer)
            guard case let .browserStatus(statusRequest) = statusClaim.request.request else {
                Issue.record("Expected browser target inspection before mutation transport")
                await peer.stop()
                return
            }
            #expect(statusRequest.channel == "stable")

            let legacyHandshake = Task {
                try await client.handshake(
                    client: Self.clientIdentity,
                    protocolVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 28))
            }
            let legacyHandshakeRequest = try await peer.nextRequest()
            let legacyHandshakePayload = try Self.requireHandshake(legacyHandshakeRequest)
            #expect(legacyHandshakePayload.replacingOperationSessionID == session.attestation.sessionID)
            try await peer.respond(.handshake(Self.legacyHandshake()), to: legacyHandshakeRequest)
            #expect(try await legacyHandshake.value.negotiatedVersion <
                PeekabooBridgeConstants.attestedOperationReceiptVersion)

            let receipt = PeekabooBridgeBrowserConnectionReceipt(
                channel: "stable",
                browserURL: "http://127.0.0.1:9222/",
                webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-concurrency",
                devToolsBrowserID: "browser-concurrency",
                browserVersion: "Chrome/151.0",
                protocolVersion: "1.3")
            let statusResponse = PeekabooBridgeResponse.browserStatus(.init(
                isConnected: true,
                toolCount: 1,
                detectedBrowsers: [],
                connectionReceipt: receipt))
            let receiptedStatus = try await Self.receiptedResponse(
                authority: authority,
                claim: statusClaim,
                response: statusResponse)
            try await peer.respond(receiptedStatus.wireResponse, to: heldStatusRequest)

            do {
                _ = try await browserMutation.value
                Issue.record("The result-aware browser mutation escaped without an operation receipt")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .refused)
                #expect(failure.outcome.refusalReason == .transportSessionUnavailable)
                #expect(failure.outcome.dispatchState == .none)
                #expect(failure.outcome.retrySafety == .safe)
            }
            #expect(await peer.acceptedConnectionCount == 3)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test
    func `receipt export failure preserves the verified mutation response and outcome`() async throws {
        let root = Self.temporaryRoot("receipt-export-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blockedExportFile = root.appendingPathComponent("not-a-directory", isDirectory: false)
        try Data("ordinary file".utf8).write(to: blockedExportFile)
        let blockedExportDirectory = URL(fileURLWithPath: blockedExportFile.path, isDirectory: true)

        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path,
            maximumClaimCount: 4,
            maximumSessionCount: 8,
            maximumActiveSessionCountPerPeer: 4,
            retainedRetiredSessionCount: 2)
        let clientInstanceID = UUID()
        let session = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let peer = try ConcurrentGatedBridgePeer()
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            requestTimeoutSec: 10,
            operationReceiptExportDirectory: blockedExportDirectory,
            operationClientInstanceID: clientInstanceID)

        do {
            let initialHandshake = Task { try await client.handshake(client: Self.clientIdentity) }
            let initialRequest = try await peer.nextRequest()
            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: session.attestation)),
                to: initialRequest)
            _ = try await initialHandshake.value

            let expectedOutcome = DesktopActionOutcome.dispatchedUnverified(
                route: .bridge,
                delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one)
            let call = Task {
                try await client.sendCarryingActionOutcome(.requestPostEventPermission)
            }
            let wireRequest = try await peer.nextRequest()
            let claim = try await Self.acceptedClaim(
                wireRequest,
                authority: authority,
                peer: session.peer)
            let response = PeekabooBridgeResponse.projectedAction(.init(
                response: .bool(true),
                outcome: expectedOutcome.projection))
            let receipted = try await Self.receiptedResponse(
                authority: authority,
                claim: claim,
                response: response)
            try await peer.respond(receipted.wireResponse, to: wireRequest)

            let reply = try await call.value
            guard case let .bool(granted) = reply.response else {
                Issue.record("Expected the verified Boolean response despite export failure")
                await peer.stop()
                return
            }
            #expect(granted)
            #expect(reply.outcome == expectedOutcome.projection)
            let bundle = try #require(await client.lastOperationReceiptBundle())
            #expect(bundle.receipt == receipted.receipt)
            let exportFailure = try #require(await client.lastOperationReceiptExportFailure())
            #expect(exportFailure.requestID == receipted.receipt.payload.requestID)
            #expect(exportFailure.directoryPath == blockedExportDirectory.standardizedFileURL.path)
            #expect(!exportFailure.message.isEmpty)
            #expect(await peer.acceptedConnectionCount == 2)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test
    func `mutating renewal cancellation is canonical while read only cancellation stays native`() async throws {
        let root = Self.temporaryRoot("pretransport-cancellation")
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path,
            maximumClaimCount: 2,
            maximumSessionCount: 8,
            maximumActiveSessionCountPerPeer: 4,
            retainedRetiredSessionCount: 2)
        let clientInstanceID = UUID()
        let predecessor = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let peer = try ConcurrentGatedBridgePeer()
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            requestTimeoutSec: 10,
            operationClientInstanceID: clientInstanceID)

        do {
            let initialHandshake = Task { try await client.handshake(client: Self.clientIdentity) }
            let initialRequest = try await peer.nextRequest()
            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: predecessor.attestation)),
                to: initialRequest)
            _ = try await initialHandshake.value
            _ = try #require(try await client.reserveOperationSession())

            let cancelledMutation = Task { try await client.send(.requestPostEventPermission) }
            let renewalRequest = try await peer.nextRequest()
            let renewalPayload = try Self.requireHandshake(renewalRequest)
            #expect(renewalPayload.replacingOperationSessionID == predecessor.attestation.sessionID)
            cancelledMutation.cancel()
            do {
                _ = try await cancelledMutation.value
                Issue.record("Expected the pre-transport mutation cancellation to fail")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .refused)
                #expect(failure.outcome.route == .bridge)
                #expect(failure.outcome.evidence == .requestRefused)
                #expect(failure.outcome.dispatchState == .none)
                #expect(failure.outcome.retrySafety == .safe)
                #expect(failure.outcome.refusalReason == .requestCancelled)
                #expect(failure.outcome.escalation == .none)
            }

            let successor = try await OperationReceiptSessionFixture.make(
                authority: authority,
                clientInstanceID: clientInstanceID,
                peer: predecessor.peer,
                replacing: predecessor.attestation.sessionID)
            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: successor.attestation)),
                to: renewalRequest)
            #expect(try await client.renewOperationSession(
                replacingSessionID: predecessor.attestation.sessionID).sessionID == successor.attestation.sessionID)

            let readOnlyGate = TestContinuationGate()
            let cancelledReadOnly = Task {
                await readOnlyGate.wait()
                return try await client.send(.permissionsStatus)
            }
            cancelledReadOnly.cancel()
            await readOnlyGate.open()
            do {
                _ = try await cancelledReadOnly.value
                Issue.record("Expected read-only cancellation to remain native")
            } catch is CancellationError {
                // Read-only callers retain ordinary Swift cancellation semantics.
            }
            #expect(await peer.acceptedConnectionCount == 2)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test
    func `explicit legacy mutation cancellation remains native`() async throws {
        let peer = try ConcurrentGatedBridgePeer()
        let client = TrustedBridgeClientFixture.make(socketPath: peer.socketPath, requestTimeoutSec: 10)

        do {
            let handshake = Task {
                try await client.handshake(
                    client: Self.clientIdentity,
                    protocolVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 28))
            }
            let handshakeRequest = try await peer.nextRequest()
            try await peer.respond(.handshake(Self.legacyHandshake()), to: handshakeRequest)
            _ = try await handshake.value

            let cancellationGate = TestContinuationGate()
            let cancelledMutation = Task {
                await cancellationGate.wait()
                return try await client.send(.requestPostEventPermission)
            }
            cancelledMutation.cancel()
            await cancellationGate.open()
            do {
                _ = try await cancelledMutation.value
                Issue.record("Expected explicit legacy cancellation to remain native")
            } catch is CancellationError {
                // Protocol 1.28 remains outside the canonical receipt/result contract.
            }
            #expect(await peer.acceptedConnectionCount == 1)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test
    func `explicit handshake superseding shared renewal is not reported as caller cancellation`() async throws {
        let root = Self.temporaryRoot("renewal-superseded-not-cancelled")
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path,
            maximumClaimCount: 2,
            maximumSessionCount: 8,
            maximumActiveSessionCountPerPeer: 4,
            retainedRetiredSessionCount: 2)
        let clientInstanceID = UUID()
        let predecessor = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let peer = try ConcurrentGatedBridgePeer()
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            requestTimeoutSec: 10,
            operationClientInstanceID: clientInstanceID)

        do {
            let initialHandshake = Task { try await client.handshake(client: Self.clientIdentity) }
            let initialRequest = try await peer.nextRequest()
            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: predecessor.attestation)),
                to: initialRequest)
            _ = try await initialHandshake.value
            _ = try #require(try await client.reserveOperationSession())

            let waitingMutation = Task { try await client.send(.requestPostEventPermission) }
            let renewalRequest = try await peer.nextRequest()
            let renewalPayload = try Self.requireHandshake(renewalRequest)
            #expect(renewalPayload.replacingOperationSessionID == predecessor.attestation.sessionID)

            let explicitHandshake = Task { try await client.handshake(client: Self.clientIdentity) }
            let explicitHandshakeRequest = try await peer.nextRequest()
            let explicitPayload = try Self.requireHandshake(explicitHandshakeRequest)
            #expect(explicitPayload.replacingOperationSessionID == predecessor.attestation.sessionID)

            do {
                _ = try await waitingMutation.value
                Issue.record("Expected the superseded renewal waiter to fail before mutation transport")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .refused)
                #expect(failure.outcome.route == .bridge)
                #expect(failure.outcome.dispatchState == .none)
                #expect(failure.outcome.retrySafety == .safe)
                #expect(failure.outcome.refusalReason == .transportSessionUnavailable)
                #expect(failure.outcome.refusalReason != .requestCancelled)
                #expect(failure.outcome.escalation == .reconnectSession)
            }

            try await peer.close(renewalRequest)
            let successor = try await OperationReceiptSessionFixture.make(
                authority: authority,
                clientInstanceID: clientInstanceID,
                peer: predecessor.peer,
                replacing: predecessor.attestation.sessionID)
            try await peer.respond(
                .handshake(Self.handshake(authority: authority, session: successor.attestation)),
                to: explicitHandshakeRequest)
            #expect(try await explicitHandshake.value.operationSessionAttestation == successor.attestation)
            #expect(await peer.acceptedConnectionCount == 3)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    static var clientIdentity: PeekabooBridgeClientIdentity {
        PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peekaboo.client-concurrency-tests",
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: nil)
    }

    private static func temporaryRoot(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-client-concurrency-\(suffix)-\(UUID().uuidString)",
            isDirectory: true)
    }

    private static func handshake(
        authority: PeekabooBridgeOperationReceiptAuthority,
        session: PeekabooBridgeOperationSessionAttestation) -> PeekabooBridgeHandshakeResponse
    {
        let listener = authority.attestation
        return BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.attestedOperationReceiptVersion,
            hostKind: .gui,
            build: "client-concurrency-test",
            supportedOperations: [
                .permissionsStatus,
                .requestPostEventPermission,
                .findApplication,
                .hideApplication,
                .browserStatus,
                .browserExecute,
            ],
            permissions: .init(screenRecording: true, accessibility: true, postEvent: true),
            enabledOperations: [
                .permissionsStatus,
                .requestPostEventPermission,
                .findApplication,
                .hideApplication,
                .browserStatus,
                .browserExecute,
            ],
            hostIdentity: .init(
                processIdentifier: listener.host.processIdentifier,
                processStartIdentity: listener.host.processStartIdentity,
                bundleIdentifier: "dev.peekaboo.client-concurrency-tests",
                bundleShortVersion: "1",
                bundleVersion: "1",
                codeSignatureHash: listener.host.codeSignatureHash),
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.desktopActionOutcomeProjection,
            ],
            operationAttestation: listener,
            operationSessionAttestation: session)
    }

    private static func legacyHandshake() -> PeekabooBridgeHandshakeResponse {
        let current = PeekabooBridgeConstants.attestedOperationReceiptVersion
        return BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: current.major, minor: current.minor - 1),
            hostKind: .gui,
            build: "client-concurrency-legacy-test",
            supportedOperations: [
                .permissionsStatus,
                .requestPostEventPermission,
                .findApplication,
                .hideApplication,
                .browserStatus,
                .browserExecute,
            ],
            permissions: .init(screenRecording: true, accessibility: true, postEvent: true),
            enabledOperations: [
                .permissionsStatus,
                .requestPostEventPermission,
                .findApplication,
                .hideApplication,
                .browserStatus,
                .browserExecute,
            ],
            hostCapabilities: [PeekabooBridgeHostCapability.desktopActionOutcomeProjection])
    }

    @discardableResult
    static func requireHandshake(
        _ request: ConcurrentGatedBridgePeer.Request) throws -> PeekabooBridgeHandshake
    {
        guard case let .handshake(payload) = try request.decode() else {
            throw ClientConcurrencyFixtureError.expectedHandshake
        }
        return payload
    }

    private static func acceptedClaim(
        _ request: ConcurrentGatedBridgePeer.Request,
        authority: PeekabooBridgeOperationReceiptAuthority,
        peer: PeekabooBridgePeer) async throws
        -> (request: PeekabooBridgeAttestedOperationRequest, claim: PeekabooBridgeOperationSessionClaim)
    {
        guard case let .attestedOperation(payload) = try request.decode() else {
            throw ClientConcurrencyFixtureError.expectedAttestedOperation
        }
        guard case let .accepted(claim) = try await authority.claim(payload, peer: peer) else {
            throw ClientConcurrencyFixtureError.expectedAcceptedClaim
        }
        return (payload, claim)
    }

    private static func receiptedPermissionsResponse(
        authority: PeekabooBridgeOperationReceiptAuthority,
        session: OperationReceiptSessionFixture,
        claim: (request: PeekabooBridgeAttestedOperationRequest, claim: PeekabooBridgeOperationSessionClaim))
        async throws
        -> (wireResponse: PeekabooBridgeResponse, receipt: PeekabooBridgeOperationReceipt)
    {
        let response = PeekabooBridgeResponse.permissionsStatus(.init(
            screenRecording: true,
            accessibility: true,
            postEvent: true))
        let payload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: claim.claim,
            request: claim.request.request,
            response: response,
            outcome: PeekabooBridgeOperationReceiptSemantics.outcome(in: response))
        let receipt = try await authority.signAndArchive(payload, claim: claim.claim)
        authority.complete(claim.claim)
        return (
            .attestedOperation(.init(response: response, receipt: receipt)),
            receipt)
    }

    private static func receiptedResponse(
        authority: PeekabooBridgeOperationReceiptAuthority,
        claim: (request: PeekabooBridgeAttestedOperationRequest, claim: PeekabooBridgeOperationSessionClaim),
        response: PeekabooBridgeResponse,
        target: PeekabooBridgeOperationTargetReceipt = .global) async throws
        -> (wireResponse: PeekabooBridgeResponse, receipt: PeekabooBridgeOperationReceipt)
    {
        let payload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: claim.claim,
            request: claim.request.request,
            response: response,
            target: target,
            outcome: PeekabooBridgeOperationReceiptSemantics.outcome(in: response))
        let receipt = try await authority.signAndArchive(payload, claim: claim.claim)
        authority.complete(claim.claim)
        return (
            .attestedOperation(.init(response: response, receipt: receipt)),
            receipt)
    }
}

private enum ClientConcurrencyFixtureError: Error {
    case expectedHandshake
    case expectedAttestedOperation
    case expectedAcceptedClaim
    case expectedRolloverRefusal
}

private actor TestContinuationGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !self.isOpen else { return }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func open() {
        guard !self.isOpen else { return }
        self.isOpen = true
        let waiters = self.waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
