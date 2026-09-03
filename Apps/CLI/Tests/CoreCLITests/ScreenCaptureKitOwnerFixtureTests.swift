import Darwin
import Foundation
import PeekabooBridge
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

extension ScreenCaptureKitOwnerRuntimeTests {
    @Test(arguments: [true, false])
    func `fixture ownership capability follows service support`(ownerAware: Bool) async throws {
        let socketPath = Self.fixtureSocketPath()
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
    func `fixture preparation failures retain ownership implementation proof`(registrationFails: Bool) async throws {
        let socketPath = Self.fixtureSocketPath()
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

        #expect(unawareHost == nil)
        let handshake = try await PeekabooBridgeClient(socketPath: socketPath).handshake(
            client: .init(bundleIdentifier: "synthetic.client", teamIdentifier: nil, processIdentifier: getpid())
        )
        #expect(handshake.screenCaptureKitReadiness?.state == .unavailable)
        #expect(handshake.screenCaptureKitReadiness?.failure?
            .stage == (registrationFails ? .registration : .preparation))
        await host.stop()
    }
}
