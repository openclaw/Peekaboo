import Foundation

@MainActor
final class VisualizerEventNotificationObserver: NSObject {
    private let notificationCenter: DistributedNotificationCenter
    private let name: Notification.Name
    private let handler: @MainActor (Notification) -> Void

    init(name: Notification.Name, handler: @escaping @MainActor (Notification) -> Void) {
        self.notificationCenter = .default()
        self.name = name
        self.handler = handler
        super.init()

        // AppKit suspends distributed notifications while the companion app is inactive.
        self.notificationCenter.addObserver(
            self,
            selector: #selector(self.receive(_:)),
            name: name,
            object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    @MainActor
    deinit {
        self.notificationCenter.removeObserver(self, name: self.name, object: nil)
    }

    /// Distributed notifications are delivered on the main thread's run loop.
    @objc private func receive(_ notification: Notification) {
        self.handler(notification)
    }
}
