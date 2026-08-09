import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import Testing

struct CaptureVisualizerModeProtocolTests {
    @Test
    func `Bridge capture visualizer modes round trip`() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for mode in [
            CaptureVisualizerMode.none,
            .screenshotFlash,
            .watchCapture,
        ] {
            let payload = PeekabooBridgeCaptureFrontmostRequest(
                visualizerMode: mode,
                scale: .logical1x)
            let encoded = try encoder.encode(payload)
            let decoded = try decoder.decode(PeekabooBridgeCaptureFrontmostRequest.self, from: encoded)
            #expect(decoded.visualizerMode == mode)
        }
    }

    @Test
    func `Silent capture is a protocol 1_12 contract`() {
        #expect(PeekabooBridgeConstants.protocolVersion >= .init(major: 1, minor: 12))
        #expect(DesktopCaptureOptions().visualizerMode == .none)
        #expect(CaptureVisualizerMode.resolved(for: .background, visibleMode: .screenshotFlash) == .none)
        #expect(CaptureVisualizerMode.resolved(for: .foreground, visibleMode: .screenshotFlash) == .screenshotFlash)
    }
}
