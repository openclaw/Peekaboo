import Darwin
import Foundation
import PeekabooBridge
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

extension ScreenCaptureKitOwnerRuntimeTests {
    @Test(arguments: [true, false])
    func `fixture ownership capability follows service support`(ownerAware: Bool) async throws {
        let socketPath = "/tmp/peekaboo-owner-fixture-\(UUID().uuidString).sock"
        let host = try await Self.startHost(
            socketPath: socketPath,
            processIdentifier: 4242,
            processStartIdentity: 9001,
            codeSignatureHash: "owner-build",
            ownerAware: ownerAware
        )
        defer { Task { await host.stop() } }

        let handshake = try await PeekabooBridgeClient(socketPath: socketPath).handshake(
            client: BridgeDiagnostics.currentClientIdentity()
        )

        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership
        ) == ownerAware)
        #expect(handshake.hostIdentity?.processIdentifier == 4242)
        #expect(handshake.hostIdentity?.processStartIdentity == 9001)
        #expect(handshake.hostIdentity?.codeSignatureHash == "owner-build")
        await host.stop()
    }

    @Test(arguments: [true, false])
    func `fixture ownership failures remain owner unaware`(registrationFails: Bool) async throws {
        let socketPath = "/tmp/peekaboo-owner-fixture-failure-\(UUID().uuidString).sock"
        let host = try await Self.startHost(
            socketPath: socketPath,
            processIdentifier: 4242,
            processStartIdentity: 9001,
            codeSignatureHash: "owner-build",
            screenCaptureKitProcessCapabilityRegistrar: {
                if registrationFails {
                    throw OperationError.captureFailed(reason: "Fixture registration failure")
                }
            },
            screenCaptureKitOwnershipPreparer: {
                #expect(!registrationFails)
                throw OperationError.captureFailed(reason: "Fixture preparation failure")
            }
        )
        defer { Task { await host.stop() } }

        let unawareHost = try await RuntimeHostResolver.firstScreenCaptureKitOwnerUnawareHost(
            candidates: [.init(
                socketPath: socketPath,
                requireReusableDaemon: false,
                requiredHostKind: nil,
                requiresValidatedHistoricalDaemon: false
            )],
            identity: BridgeDiagnostics.currentClientIdentity(),
            externalHostPresence: { _ in .absent }
        )

        #expect(unawareHost?.socketPath == socketPath)
        #expect(unawareHost?.processIdentifier == 4242)
        #expect(unawareHost?.processStartIdentity == 9001)
        await host.stop()
    }
}
