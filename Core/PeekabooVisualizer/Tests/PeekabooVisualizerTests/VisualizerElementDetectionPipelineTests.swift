import AppKit
import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import PeekabooVisualizer

/// End-to-end proof of the sender → event → renderer decision for element boxes.
///
/// Guards Finding 1: because the default-off gate lives in the sender, a dispatched
/// element-detection event must render even when no per-feature setting opted in. The
/// old double-gate (a `elementDetectionEnabled ?? false` check in the renderer) would
/// have swallowed the event here and failed the positive case.
///
/// Serialized because it mutates process environment (`PEEKABOO_VISUALIZER_*`).
@Suite(.serialized)
@MainActor
struct VisualizerElementDetectionPipelineTests {
    @Test
    func `Dispatched element event renders without a per-feature renderer gate`() async throws {
        try await self.withForcedVisualizerAppStorage { storageDir in
            unsetenv("PEEKABOO_VISUAL_ELEMENT_BOXES")

            let screen = try #require(NSScreen.screens.first)
            let element = CGRect(
                x: screen.frame.midX - 20,
                y: screen.frame.midY - 10,
                width: 40,
                height: 20)

            // Sender persists + notifies (env not "false", forced app context).
            let client = VisualizationClient()
            client.connect()
            #expect(await client.showElementDetection(elements: ["B1": element], duration: 60))

            // Event: load exactly what the receiver would decode off disk.
            let event = try loadOnlyPersistedEvent(in: storageDir)
            guard case let .elementDetection(elements, duration) = event.payload else {
                Issue.record("Persisted payload was not .elementDetection")
                return
            }
            #expect(elements["B1"] == element)

            // Renderer: a fresh coordinator with no settings source connected must still draw.
            let coordinator = VisualizerCoordinator()
            defer { coordinator.overlayManager.removeAllWindows() }
            #expect(await coordinator.showElementDetection(elements: elements, duration: duration))
            #expect(coordinator.overlayManager.activeReplaceKeys.contains(
                VisualizerCoordinator.OverlaySlot.elementSheet(screenIndex: 0)))
        }
    }

    @Test
    func `Env off switch stops the sender from dispatching an element event`() async throws {
        try await self.withForcedVisualizerAppStorage { storageDir in
            setenv("PEEKABOO_VISUAL_ELEMENT_BOXES", "false", 1)
            defer { unsetenv("PEEKABOO_VISUAL_ELEMENT_BOXES") }

            let client = VisualizationClient()
            client.connect()
            #expect(await client.showElementDetection(
                elements: ["B1": CGRect(x: 0, y: 0, width: 10, height: 10)],
                duration: 60) == false)

            let count = try persistedEventCount(in: storageDir)
            #expect(count == 0)
        }
    }

    // MARK: - Helpers

    private func withForcedVisualizerAppStorage(_ body: (URL) async throws -> Void) async throws {
        let storageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-visualizer-pipe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)

        let previousStorage = getenv("PEEKABOO_VISUALIZER_STORAGE").map { String(cString: $0) }
        let previousForceApp = getenv("PEEKABOO_VISUALIZER_FORCE_APP").map { String(cString: $0) }
        setenv("PEEKABOO_VISUALIZER_STORAGE", storageDir.path, 1)
        setenv("PEEKABOO_VISUALIZER_FORCE_APP", "true", 1)

        defer {
            if let previousStorage {
                setenv("PEEKABOO_VISUALIZER_STORAGE", previousStorage, 1)
            } else {
                unsetenv("PEEKABOO_VISUALIZER_STORAGE")
            }
            if let previousForceApp {
                setenv("PEEKABOO_VISUALIZER_FORCE_APP", previousForceApp, 1)
            } else {
                unsetenv("PEEKABOO_VISUALIZER_FORCE_APP")
            }
            try? FileManager.default.removeItem(at: storageDir)
        }

        try await body(storageDir)
    }

    private func persistedEventURLs(in storageDir: URL) throws -> [URL] {
        let eventsDir = storageDir.appendingPathComponent("VisualizerEvents", isDirectory: true)
        guard FileManager.default.fileExists(atPath: eventsDir.path) else { return [] }
        return try FileManager.default
            .contentsOfDirectory(at: eventsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    private func persistedEventCount(in storageDir: URL) throws -> Int {
        try self.persistedEventURLs(in: storageDir).count
    }

    private func loadOnlyPersistedEvent(in storageDir: URL) throws -> VisualizerEvent {
        let urls = try self.persistedEventURLs(in: storageDir)
        let url = try #require(urls.first)
        let id = try #require(UUID(uuidString: url.deletingPathExtension().lastPathComponent))
        return try VisualizerEventStore.loadEvent(id: id)
    }
}
