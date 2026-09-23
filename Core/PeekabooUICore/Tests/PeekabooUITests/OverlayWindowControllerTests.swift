import AppKit
import os
import Testing
@testable import PeekabooUICore

struct OverlayWindowControllerTests {
    @MainActor
    @Test
    func `screen notifications stop and repeated starts deliver only once`() {
        let manager = OverlayManager(enableMonitoring: false)
        let center = CountingNotificationCenter()
        let controller = OverlayWindowController(overlayManager: manager, notificationCenter: center)
        defer {
            controller.stopMonitoringScreenChanges()
            manager.cleanup()
        }

        controller.startMonitoringScreenChanges()
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(center.deliveryCount == 1)

        controller.startMonitoringScreenChanges()
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(center.deliveryCount == 2)

        controller.stopMonitoringScreenChanges()
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(center.deliveryCount == 2)

        controller.stopMonitoringScreenChanges()
        controller.startMonitoringScreenChanges()
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(center.deliveryCount == 3)
    }

    @MainActor
    @Test
    func `destroying a monitoring controller unregisters its observer`() {
        let manager = OverlayManager(enableMonitoring: false)
        defer { manager.cleanup() }
        let center = CountingNotificationCenter()
        var controller: OverlayWindowController? = OverlayWindowController(
            overlayManager: manager,
            notificationCenter: center)
        weak var releasedController = controller
        controller?.startMonitoringScreenChanges()
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(center.deliveryCount == 1)

        controller = nil
        #expect(releasedController == nil)
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(center.deliveryCount == 1)
    }
}

private final nonisolated class CountingNotificationCenter: NotificationCenter, @unchecked Sendable {
    private let deliveries = OSAllocatedUnfairLock(initialState: 0)

    var deliveryCount: Int {
        self.deliveries.withLock { $0 }
    }

    override func addObserver(
        forName name: NSNotification.Name?,
        object obj: Any?,
        queue: OperationQueue?,
        using block: @Sendable @escaping (Notification) -> Void) -> any NSObjectProtocol
    {
        let deliveries = self.deliveries
        return super.addObserver(forName: name, object: obj, queue: queue) { notification in
            deliveries.withLock { $0 += 1 }
            block(notification)
        }
    }
}
