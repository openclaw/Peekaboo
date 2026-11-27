import Foundation
import PeekabooFoundation
import PeekabooProtocols
import PeekabooVisualizer
import Testing

@MainActor
struct VisualizerEventStoreContractTests {
    @Test
    func `Target window context round-trips as an additive payload field`() throws {
        let target = VisualizerTargetWindow(
            processIdentifier: 123,
            windowID: 456,
            frame: CGRect(x: 10, y: 20, width: 800, height: 600))
        let payload = VisualizerEvent.Payload.hotkeyDisplay(
            keys: ["cmd", "shift", "t"],
            duration: 1,
            target: target)

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(VisualizerEvent.Payload.self, from: data)
        guard case let .hotkeyDisplay(_, _, decodedTarget) = decoded else {
            Issue.record("Decoded payload mismatch")
            return
        }
        #expect(decodedTarget == target)

        let legacyDecoded = try JSONDecoder().decode(LegacyHotkeyPayload.self, from: data)
        guard case let .hotkeyDisplay(keys, duration) = legacyDecoded else {
            Issue.record("Legacy payload mismatch")
            return
        }
        #expect(keys == ["cmd", "shift", "t"])
        #expect(duration == 1)
    }

    @Test
    func `Legacy payload without target context still decodes`() throws {
        let payload = VisualizerEvent.Payload.clickFeedback(point: .zero, type: .single)

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(VisualizerEvent.Payload.self, from: data)
        guard case let .clickFeedback(_, _, target) = decoded else {
            Issue.record("Decoded payload mismatch")
            return
        }
        #expect(target == nil)
    }

    @Test
    func `Payload encoding round-trips annotated screenshot`() throws {
        let payload = VisualizerEvent.Payload.annotatedScreenshot(
            imageData: Data([0x89, 0x50]),
            elements: [DetectedElement(
                id: "A1",
                type: .button,
                bounds: .zero,
                label: nil,
                value: nil,
                isEnabled: true)],
            windowBounds: .zero,
            duration: 1.0)

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(VisualizerEvent.Payload.self, from: data)
        switch decoded {
        case let .annotatedScreenshot(_, elements, _, _):
            #expect(elements.count == 1)
        default:
            Issue.record("Decoded payload mismatch")
        }
    }

    @Test
    func `Arrow payload round-trips a global display rectangle and sticky lifetime`() throws {
        let target = VisualizerArrowTarget.rect(CGRect(x: -20, y: 40, width: 120, height: 36))
        let payload = VisualizerEvent.Payload.arrow(
            target: target,
            label: "Open settings",
            duration: 3,
            sticky: true)

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(VisualizerEvent.Payload.self, from: data)
        guard case let .arrow(decodedTarget, label, duration, sticky) = decoded else {
            Issue.record("Decoded arrow payload mismatch")
            return
        }

        #expect(decodedTarget == target)
        #expect(label == "Open settings")
        #expect(duration == 3)
        #expect(sticky)
    }

    @Test
    func `Arrow dismissal payload round-trips its guidance identifier`() throws {
        let id = UUID()
        let data = try JSONEncoder().encode(VisualizerEvent.Payload.arrowDismiss(id: id))
        let decoded = try JSONDecoder().decode(VisualizerEvent.Payload.self, from: data)
        guard case let .arrowDismiss(decodedID) = decoded else {
            Issue.record("Decoded arrow dismissal payload mismatch")
            return
        }

        #expect(decodedID == id)
    }
}

private enum LegacyHotkeyPayload: Codable {
    case hotkeyDisplay(keys: [String], duration: TimeInterval)
}
