//
//  VisualizerEventReceiver.swift
//  Peekaboo
//

@preconcurrency import Foundation
import os
import PeekabooFoundation
import PeekabooProtocols

#if VISUALIZER_VERBOSE_LOGS
@inline(__always)
private func visualizerDebugLog(_ message: @autoclosure () -> String) {
    NSLog("%@", message())
}
#else
@inline(__always)
private func visualizerDebugLog(_ message: @autoclosure () -> String) {}
#endif

@MainActor
public final class VisualizerEventReceiver {
    private let logger = os.Logger(subsystem: "boo.peekaboo.visualizer", category: "VisualizerEventReceiver")
    private let coordinator: VisualizerCoordinator
    private var observer: (any NSObjectProtocol)?
    private var cleanupTask: Task<Void, Never>?

    public init(visualizerCoordinator: VisualizerCoordinator) {
        self.coordinator = visualizerCoordinator
        self.observer = DistributedNotificationCenter.default().addObserver(
            forName: .visualizerEventDispatched,
            object: nil,
            queue: .main)
        { [weak self] notification in
            guard let descriptor = notification.object as? String else {
                self?.logger.error("Visualizer notification missing identifier")
                return
            }

            Task { @MainActor [weak self] in
                await self?.handle(descriptor: descriptor)
            }
        }

        self.cleanupTask = Task.detached(priority: .background) {
            try? VisualizerEventStore.cleanup(olderThan: 600)
        }

        self.logger.info("Visualizer event receiver registered for distributed notifications")
        visualizerDebugLog("VisualizerEventReceiver: registered for distributed notifications")
    }

    @MainActor
    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        cleanupTask?.cancel()
    }

    private func handle(descriptor: String) async {
        visualizerDebugLog("VisualizerEventReceiver: received descriptor \(descriptor)")
        guard let eventID = Self.parseEventID(from: descriptor) else {
            self.logger.error(
                "Visualizer notification contained invalid identifier: \(descriptor)")
            return
        }

        let event: VisualizerEvent
        do {
            event = try VisualizerEventStore.loadEvent(id: eventID)
        } catch {
            let failureMessage = "Failed to load visualizer event \(eventID.uuidString)"
            self.logger.error("\(failureMessage): \(error.localizedDescription)")
            visualizerDebugLog(
                "VisualizerEventReceiver: failed to load event \(eventID.uuidString) - \(error.localizedDescription)")
            return
        }

        visualizerDebugLog("VisualizerEventReceiver: executing event \(eventID.uuidString)")

        await self.execute(event: event)

        do {
            try VisualizerEventStore.removeEvent(id: eventID)
            visualizerDebugLog("VisualizerEventReceiver: deleted event \(eventID.uuidString)")
        } catch {
            let failureMessage = "Failed to delete visualizer event \(eventID.uuidString)"
            self.logger.error("\(failureMessage): \(error.localizedDescription)")
            visualizerDebugLog(
                "VisualizerEventReceiver: failed to delete event \(eventID.uuidString) - \(error.localizedDescription)")
        }
    }

    private func execute(event: VisualizerEvent) async {
        self.logger.debug("Processing visualizer event \(event.kind.rawValue)")
        let success: Bool = switch event.payload {
        case let .screenshotFlash(rect):
            await self.coordinator.showScreenshotFlash(in: rect)
        case let .watchCapture(rect):
            await self.coordinator.showWatchCapture(in: rect)
        case let .clickFeedback(point, type, target):
            await self.coordinator.showClickFeedback(at: point, type: type, target: target)
        case let .typingFeedback(keys, duration, cadence, target):
            await self.coordinator.showTypingFeedback(
                keys: keys,
                duration: duration,
                cadence: cadence,
                target: target)
        case let .scrollFeedback(point, direction, amount, target):
            await self.coordinator.showScrollFeedback(
                at: point,
                direction: direction,
                amount: amount,
                target: target)
        case let .mouseMovement(from, to, duration, target):
            await self.coordinator.showMouseMovement(from: from, to: to, duration: duration, target: target)
        case let .swipeGesture(from, to, duration, target):
            await self.coordinator.showSwipeGesture(from: from, to: to, duration: duration, target: target)
        case let .hotkeyDisplay(keys, duration, target):
            await self.coordinator.showHotkeyDisplay(keys: keys, duration: duration, target: target)
        case .appLaunch, .appQuit, .windowOperation, .menuNavigation, .dialogInteraction, .spaceSwitch:
            true
        case let .elementDetection(elements, duration):
            await self.coordinator.showElementDetection(elements: elements, duration: duration)
        case let .annotatedScreenshot(imageData, elements, windowBounds, duration):
            await self.coordinator.showAnnotatedScreenshot(
                imageData: imageData,
                elements: elements,
                windowBounds: windowBounds,
                duration: duration)
        }

        if !success {
            self.logger.warning("Visualizer event \(event.kind.rawValue) reported failure")
        }
    }

    private static func parseEventID(from descriptor: String) -> UUID? {
        descriptor.split(separator: "|", maxSplits: 1).first.flatMap { UUID(uuidString: String($0)) }
    }

    // DetectedElement is already part of the VisualizerEvent payload contract (PeekabooProtocols).
}
