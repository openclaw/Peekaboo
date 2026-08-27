import PeekabooAutomationKit
import Testing
@testable import PeekabooBridge

@MainActor
struct DesktopObservationCapturePolicyTests {
    @Test
    func `Bridge auto screen policy preserves explicit foreground non-screen and ownerless requests`() {
        let backgroundScreen = DesktopObservationRequest(
            target: .screen(index: 0),
            capture: .init(engine: .auto, focus: .background))
        #expect(PeekabooBridgeServer.desktopObservationExecutionRequest(
            backgroundScreen,
            hostRegisteredScreenCaptureKitOwnership: true).capture.engine == .modern)
        #expect(PeekabooBridgeServer.desktopObservationExecutionRequest(
            backgroundScreen,
            hostRegisteredScreenCaptureKitOwnership: false) == backgroundScreen)

        for engine in [CaptureEnginePreference.legacy, .modern] {
            let explicit = DesktopObservationRequest(
                target: .screen(index: 0),
                capture: .init(engine: engine, focus: .background))
            #expect(PeekabooBridgeServer.desktopObservationExecutionRequest(
                explicit,
                hostRegisteredScreenCaptureKitOwnership: true) == explicit)
        }

        let foreground = DesktopObservationRequest(
            target: .screen(index: 0),
            capture: .init(engine: .auto, focus: .foreground))
        let window = DesktopObservationRequest(
            target: .windowID(42),
            capture: .init(engine: .auto, focus: .background))
        #expect(PeekabooBridgeServer.desktopObservationExecutionRequest(
            foreground,
            hostRegisteredScreenCaptureKitOwnership: true) == foreground)
        #expect(PeekabooBridgeServer.desktopObservationExecutionRequest(
            window,
            hostRegisteredScreenCaptureKitOwnership: true) == window)
    }
}
