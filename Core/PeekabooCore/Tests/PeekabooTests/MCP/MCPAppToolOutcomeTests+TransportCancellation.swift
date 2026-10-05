import Darwin
import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooCore
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooBridge

extension MCPAppToolOutcomeTests {
    @Test
    @MainActor
    func `public quit all preserves actual transport response loss through later cancellation`() async throws {
        let peer = try ConcurrentGatedBridgePeer()
        do {
            try await Self.exerciseTransportCancellation(peer: peer)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @MainActor
    private static func exerciseTransportCancellation(peer: ConcurrentGatedBridgePeer) async throws {
        let gate = NoncooperativeWorkGate()
        let authority = try PeekabooBridgeOperationReceiptAuthority(socketPath: peer.socketPath)
        let clientInstanceID = UUID()
        let session = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let client = BridgeTestFixtures.authenticatedClient(
            socketPath: peer.socketPath,
            operationClientInstanceID: clientInstanceID)
        let remote = RemoteApplicationService(client: client, supportsPinnedQuit: true)
        var transportOutcome: DesktopActionOutcome?
        let service = ScriptedQuitAllApplicationService(attempts: [
            .operation { request in
                do {
                    return try await remote.quitApplicationActionResult(request: request)
                } catch let failure as DesktopActionFailure {
                    transportOutcome = failure.outcome
                    throw failure
                }
            },
            .operation { _ in
                await gate.wait()
                try Task.checkCancellation()
                Issue.record("The second quit must be cancelled before any transport request")
                return DesktopActionResult(payload: false, outcome: nil)
            },
        ])
        let context = await MCPToolTestHelpers.makeContext(
            applications: service,
            executionPolicy: .foregroundAllowed)
        let execution = Task { @MainActor in
            _ = try await client.handshake(client: .init(
                bundleIdentifier: "dev.peekaboo.quit-cancellation-tests",
                teamIdentifier: nil,
                processIdentifier: getpid(),
                hostname: nil))
            return try await context.execute(
                tool: AppTool(context: context),
                arguments: ToolArguments(raw: ["action": "quit", "all": true]))
        }
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            execution.cancel()
            await gate.release()
            await peer.stop()
        }

        do {
            let handshake = try await peer.nextRequest()
            guard case .handshake = try handshake.decode() else {
                throw TransportCancellationFixtureError.unexpectedRequest
            }
            let listener = authority.attestation
            try await peer.respond(.handshake(BridgeTestFixtures.handshake(
                negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
                supportedOperations: [.quitApplication],
                enabledOperations: [.quitApplication],
                hostIdentity: .init(
                    processIdentifier: listener.host.processIdentifier,
                    processStartIdentity: listener.host.processStartIdentity,
                    bundleIdentifier: "dev.peekaboo.quit-cancellation-tests",
                    bundleShortVersion: "1",
                    bundleVersion: "1",
                    codeSignatureHash: listener.host.codeSignatureHash),
                hostCapabilities: [
                    PeekabooBridgeHostCapability.attestedOperationReceipts,
                    PeekabooBridgeHostCapability.desktopActionOutcomeProjection,
                ],
                operationAttestation: listener,
                operationSessionAttestation: session.attestation)), to: handshake)

            let request = try await peer.nextRequest()
            guard case let .attestedOperation(payload) = try request.decode(),
                  case let .projectedAction(projected) = payload.request,
                  case let .quitApplication(quit) = projected.request,
                  case .accepted = try await authority.claim(payload, peer: session.peer)
            else {
                throw TransportCancellationFixtureError.unexpectedRequest
            }
            #expect(quit.identifier == "PID:790")
            #expect(quit.expectedIdentity?.processIdentifier == 790)
            #expect(quit.expectedIdentity?.processStartIdentity == 990)
            #expect(!quit.force)
            // The complete authenticated request arrived, but no response or native handler runs.
            try await peer.close(request)
            await gate.waitUntilBlocked()
            try #require(await gate.hasEntered)
            execution.cancel()
            await gate.release()
            let response = try await execution.value

            let expected = DesktopActionOutcome.indeterminate(route: .bridge, evidence: .responseLost)
            #expect(transportOutcome == expected)
            #expect(response.isError)
            #expect(execution.isCancelled)
            #expect(service.attemptCount == 2)
            try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(expected, in: response)
            let meta = try #require(response.meta?.objectValue)
            #expect(meta["cancelled"] == .bool(true))
            #expect(meta["quit_count"] == .double(0))
            #expect(meta["failed"] == .array([.string("First Quit App")]))
            #expect(meta["delivery_mode"] == nil)
            #expect(meta["delivery_mechanism"] == nil)
            #expect(await peer.acceptedConnectionCount == 2)
            #expect(await peer.requests.count == 2)
        } catch {
            execution.cancel()
            await gate.release()
            await peer.stop()
            _ = await execution.result
            watchdog.cancel()
            await watchdog.value
            throw error
        }
        watchdog.cancel()
        await watchdog.value
    }
}

private enum TransportCancellationFixtureError: Error {
    case unexpectedRequest
}
