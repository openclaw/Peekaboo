import PeekabooAutomationKit
import Testing
@testable import PeekabooBridge

@MainActor
struct DesktopObservationCapturePolicyTests {
    @Test
    func `Bridge auto screen policy preserves explicit foreground non-screen and ownerless requests`() {
        let hostIdentity = PeekabooBridgeHostIdentity(
            processIdentifier: 42,
            processStartIdentity: 84,
            bundleIdentifier: nil,
            bundleShortVersion: nil,
            bundleVersion: nil,
            codeSignatureHash: nil)
        let ownerReceipt = ScreenCaptureKitOwnerLease.OwnerReceipt(
            processIdentifier: 42,
            processStartIdentity: 84)
        let differentProcessReceipt = ScreenCaptureKitOwnerLease.OwnerReceipt(
            processIdentifier: 43,
            processStartIdentity: 84)
        let differentGenerationReceipt = ScreenCaptureKitOwnerLease.OwnerReceipt(
            processIdentifier: 42,
            processStartIdentity: 85)
        let backgroundScreen = DesktopObservationRequest(
            target: .screen(index: 0),
            capture: .init(engine: .auto, focus: .background))
        #expect(PeekabooBridgeServer.desktopObservationExecutionRequest(
            backgroundScreen,
            hostRegisteredScreenCaptureKitOwnership: true,
            hostIdentity: hostIdentity,
            currentScreenCaptureKitOwnerReceipt: ownerReceipt).capture.engine == .modern)
        #expect(PeekabooBridgeServer.desktopObservationExecutionRequest(
            backgroundScreen,
            hostRegisteredScreenCaptureKitOwnership: false,
            hostIdentity: hostIdentity,
            currentScreenCaptureKitOwnerReceipt: ownerReceipt) == backgroundScreen)
        #expect(PeekabooBridgeServer.desktopObservationExecutionRequest(
            backgroundScreen,
            hostRegisteredScreenCaptureKitOwnership: true,
            hostIdentity: hostIdentity,
            currentScreenCaptureKitOwnerReceipt: nil) == backgroundScreen)
        #expect(PeekabooBridgeServer.desktopObservationExecutionRequest(
            backgroundScreen,
            hostRegisteredScreenCaptureKitOwnership: true,
            hostIdentity: hostIdentity,
            currentScreenCaptureKitOwnerReceipt: differentProcessReceipt) == backgroundScreen)
        #expect(PeekabooBridgeServer.desktopObservationExecutionRequest(
            backgroundScreen,
            hostRegisteredScreenCaptureKitOwnership: true,
            hostIdentity: hostIdentity,
            currentScreenCaptureKitOwnerReceipt: differentGenerationReceipt) == backgroundScreen)

        for engine in [CaptureEnginePreference.legacy, .modern] {
            let explicit = DesktopObservationRequest(
                target: .screen(index: 0),
                capture: .init(engine: engine, focus: .background))
            #expect(PeekabooBridgeServer.desktopObservationExecutionRequest(
                explicit,
                hostRegisteredScreenCaptureKitOwnership: true,
                hostIdentity: hostIdentity,
                currentScreenCaptureKitOwnerReceipt: ownerReceipt) == explicit)
        }

        let foreground = DesktopObservationRequest(
            target: .screen(index: 0),
            capture: .init(engine: .auto, focus: .foreground))
        let window = DesktopObservationRequest(
            target: .windowID(42),
            capture: .init(engine: .auto, focus: .background))
        #expect(PeekabooBridgeServer.desktopObservationExecutionRequest(
            foreground,
            hostRegisteredScreenCaptureKitOwnership: true,
            hostIdentity: hostIdentity,
            currentScreenCaptureKitOwnerReceipt: ownerReceipt) == foreground)
        #expect(PeekabooBridgeServer.desktopObservationExecutionRequest(
            window,
            hostRegisteredScreenCaptureKitOwnership: true,
            hostIdentity: hostIdentity,
            currentScreenCaptureKitOwnerReceipt: ownerReceipt) == window)
    }
}
