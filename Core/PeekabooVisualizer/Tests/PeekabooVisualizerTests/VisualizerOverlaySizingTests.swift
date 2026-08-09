import AppKit
import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooVisualizer

@MainActor
struct VisualizerOverlaySizingTests {
    @Test
    func `Global display geometry converts to AppKit on every screen arrangement`() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)

        #expect(VisualizerScreenGeometry.appKitPoint(
            fromGlobalDisplay: CGPoint(x: 100, y: 50),
            primaryScreenFrame: primary) == CGPoint(x: 100, y: 850))
        #expect(VisualizerScreenGeometry.appKitRect(
            fromGlobalDisplay: CGRect(x: 100, y: -1100, width: 200, height: 40),
            primaryScreenFrame: primary) == CGRect(x: 100, y: 1960, width: 200, height: 40))
        #expect(VisualizerScreenGeometry.appKitRect(
            fromGlobalDisplay: CGRect(x: -300, y: 1000, width: 200, height: 40),
            primaryScreenFrame: primary) == CGRect(x: -300, y: -140, width: 200, height: 40))
    }

    @Test
    func `Global display conversion preserves logical point sizes`() {
        let converted = VisualizerScreenGeometry.appKitRect(
            fromGlobalDisplay: CGRect(x: 10, y: 20, width: 320, height: 44),
            primaryScreenFrame: CGRect(x: 0, y: 0, width: 3200, height: 1800))

        #expect(converted.size == CGSize(width: 320, height: 44))
    }

    @Test
    func `Typed text shows verbatim unless masking is requested`() {
        let keys = ["H", "i", " ", "{return}", "{tab}", "4"]

        // Default: the caption shows what is typed.
        #expect(VisualizationClient.maskedTypingKeys(keys, mask: false) == keys)

        // Secure fields / env opt-in: printable characters become bullets,
        // control glyphs stay readable.
        let masked = VisualizationClient.maskedTypingKeys(keys, mask: true)
        #expect(masked == ["•", "•", "•", "{return}", "{tab}", "•"])
    }

    @Test
    func `Element overlays drop containers and cap the count`() {
        var elements: [String: CGRect] = [
            "window": CGRect(x: 0, y: 0, width: 1400, height: 860),
            "tiny": CGRect(x: 10, y: 10, width: 2, height: 2),
        ]
        for index in 0..<150 {
            elements["e\(index)"] = CGRect(x: Double(index), y: 0, width: 40, height: 20 + Double(index % 7))
        }

        let filtered = VisualizerCoordinator.filteredElementOverlays(
            elements,
            screenArea: 1440 * 900,
            limit: 120)

        #expect(filtered["window"] == nil)
        #expect(filtered["tiny"] == nil)
        #expect(filtered.count == 120)
    }

    @Test
    func `Element overlays render on the visualizer switch, not a per-feature gate`() async throws {
        // Option (a): the sender (SeeTool / VisualizationClient) owns the default-off
        // decision, so the renderer must draw whatever it is handed once the top-level
        // visualizer switch is on — a second renderer gate would swallow the env/config opt-in.
        let coordinator = VisualizerCoordinator()
        defer { coordinator.overlayManager.removeAllWindows() }
        let screen = try #require(NSScreen.screens.first)
        let element = CGRect(
            x: screen.frame.midX - 20,
            y: screen.frame.midY - 10,
            width: 40,
            height: 20)

        // No settings source connected: the visualizer switch defaults on, so it renders.
        #expect(await coordinator.displayElementOverlays(elements: ["B1": element], duration: 60))
        #expect(coordinator.overlayManager.activeReplaceKeys.contains(
            VisualizerCoordinator.OverlaySlot.elementSheet(screenIndex: 0)))

        // Visualizer switch off ⇒ nothing renders regardless of the sender decision.
        let settings = StubVisualizerSettings()
        settings.visualizerEnabled = false
        coordinator.connectSettings(settings)
        _ = await coordinator.displayElementOverlays(elements: [:], duration: 60)
        #expect(await coordinator.displayElementOverlays(elements: ["B1": element], duration: 60) == false)
    }

    @Test
    func `Empty element refresh retires stale screen sheets`() async throws {
        let coordinator = VisualizerCoordinator()
        defer { coordinator.overlayManager.removeAllWindows() }
        let screen = try #require(NSScreen.screens.first)
        let element = CGRect(
            x: screen.frame.midX - 20,
            y: screen.frame.midY - 10,
            width: 40,
            height: 20)

        _ = await coordinator.displayElementOverlays(elements: ["B1": element], duration: 60)
        #expect(coordinator.overlayManager.activeReplaceKeys.contains(
            VisualizerCoordinator.OverlaySlot.elementSheet(screenIndex: 0)))

        _ = await coordinator.displayElementOverlays(elements: [:], duration: 60)
        #expect(coordinator.overlayManager.activeReplaceKeys
            .allSatisfy { !$0.hasPrefix(VisualizerCoordinator.OverlaySlot.elementSheetPrefix) })
    }

    @Test
    func `Window-local rects flip AppKit coordinates`() {
        let windowRect = CGRect(x: 100, y: 200, width: 400, height: 300)
        let local = VisualizerCoordinator.windowLocalRect(
            CGRect(x: 150, y: 400, width: 60, height: 40),
            in: windowRect)

        // AppKit rect top (y 440) sits 60pt below the window top (maxY 500).
        #expect(local == CGRect(x: 50, y: 60, width: 60, height: 40))
    }

    @Test
    func `Travel window rect covers both endpoints with padding`() {
        let from = CGPoint(x: 500, y: 900)
        let to = CGPoint(x: 200, y: 300)
        let rect = VisualizerCoordinator.travelWindowRect(from: from, to: to, padding: 50)

        #expect(rect == CGRect(x: 150, y: 250, width: 400, height: 700))
    }

    @Test
    func `Window-local points flip AppKit coordinates`() {
        let windowRect = CGRect(x: 100, y: 200, width: 400, height: 300)

        // Bottom-left corner of the window in screen space is the
        // bottom-left in SwiftUI space too, but y measures from the top.
        let bottomLeft = VisualizerCoordinator.windowLocalPoint(CGPoint(x: 100, y: 200), in: windowRect)
        #expect(bottomLeft == CGPoint(x: 0, y: 300))

        let topRight = VisualizerCoordinator.windowLocalPoint(CGPoint(x: 500, y: 500), in: windowRect)
        #expect(topRight == CGPoint(x: 400, y: 0))
    }

    @Test
    func `Agent cursor path is curved and lands exactly`() {
        let path = AgentCursorPath(
            from: CGPoint(x: 20, y: 40),
            to: CGPoint(x: 1020, y: 640))

        #expect(path.point(at: 0) == CGPoint(x: 20, y: 40))
        #expect(path.point(at: 1) == CGPoint(x: 1020, y: 640))
        let midpoint = path.point(at: 0.5)
        #expect(hypot(midpoint.x - 520, midpoint.y - 340) > 1)
    }

    @Test
    func `Agent cursor duration is not multiplied by visualizer slowdown`() {
        let coordinator = VisualizerCoordinator()
        let duration = coordinator.scaledDuration(for: 0.6, minimum: 0.12, applySlowdown: false)

        #expect(abs(duration - 0.6) < 0.001)
    }

    @Test
    func `Invisible target suppresses window feedback before enqueue`() async {
        let coordinator = VisualizerCoordinator(targetWindowVisibility: { _ in false })
        let target = VisualizerTargetWindow(
            processIdentifier: 42,
            windowID: 7,
            frame: CGRect(x: 100, y: 100, width: 800, height: 600))

        #expect(await coordinator.showClickFeedback(at: .zero, type: .single, target: target) == false)
        #expect(await coordinator.showTypingFeedback(
            keys: ["hidden"],
            duration: 1,
            cadence: nil,
            target: target) == false)
        #expect(await coordinator.showScrollFeedback(
            at: .zero,
            direction: .down,
            amount: 1,
            target: target) == false)
        #expect(await coordinator.showHotkeyDisplay(keys: ["cmd", "k"], duration: 1, target: target) == false)

        let queueStatus = await coordinator.animationQueue.getStatus()
        #expect(queueStatus.active == 0)
        #expect(queueStatus.queued == 0)
    }

    @Test
    func `Input HUD requires a target window`() async {
        let coordinator = VisualizerCoordinator(targetWindowVisibility: { _ in true })
        #expect(await coordinator.showTypingFeedback(
            keys: ["no anchor"],
            duration: 1,
            cadence: nil,
            target: nil) == false)
        let queueStatus = await coordinator.animationQueue.getStatus()
        #expect(queueStatus.active == 0)
        #expect(queueStatus.queued == 0)
    }

    @Test
    func `Input HUD revalidates the target at presentation time`() async {
        var evaluations = 0
        let coordinator = VisualizerCoordinator(targetWindowVisibility: { _ in
            evaluations += 1
            return evaluations == 1
        })
        let target = VisualizerTargetWindow(
            processIdentifier: 42,
            windowID: 7,
            frame: CGRect(x: 100, y: 100, width: 800, height: 600))

        #expect(await coordinator.showTypingFeedback(
            keys: ["private"],
            duration: 1,
            cadence: nil,
            target: target) == false)
        #expect(evaluations == 2)
        #expect(coordinator.overlayManager.activeReplaceKeys.isEmpty)
    }
}

/// Host-settings stand-in with every animation on. Element-detection boxes are gated in
/// the sender, not this protocol, so there is no `elementDetectionEnabled` member here.
@MainActor
private final class StubVisualizerSettings: VisualizerSettingsProviding {
    var visualizerEnabled = true
    var visualizerAnimationSpeed = 1.0
    var visualizerEffectIntensity = 1.0

    var agentCursorEnabled = true
    var inputHUDEnabled = true
    var captureIndicatorsEnabled = true
}
