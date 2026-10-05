import Foundation
import Testing
@testable import PeekabooVisualizer

@Suite(.serialized)
@MainActor
struct VisualizerEventNotificationObserverTests {
    @Test
    func `Ordinary notifications arrive while the receiver is suspended`() async throws {
        let center = DistributedNotificationCenter.default()
        let wasSuspended = center.suspended
        defer { center.suspended = wasSuspended }
        center.suspended = true

        let name = Notification.Name("boo.peekaboo.test.visualizer.\(UUID().uuidString)")
        let descriptor = "\(UUID().uuidString)|screenshotFlash"
        var received: [String] = []
        let observer = VisualizerEventNotificationObserver(name: name) { notification in
            if let value = notification.object as? String {
                received.append(value)
            }
        }
        defer { withExtendedLifetime(observer) {} }
        center.post(name: name, object: descriptor)
        try await self.waitForDelivery(until: { received.count == 1 })
        #expect(received == [descriptor])
        #expect(center.suspended)
    }

    @Test
    func `Subscription filters names and stops delivery when released`() async throws {
        let center = DistributedNotificationCenter.default()
        let name = Notification.Name("boo.peekaboo.test.visualizer.\(UUID().uuidString)")
        var received: [String] = []
        var observer: VisualizerEventNotificationObserver?
        observer = VisualizerEventNotificationObserver(name: name) { notification in
            if let value = notification.object as? String {
                received.append(value)
            }
        }
        weak var weakObserver = observer
        center.post(name: Notification.Name("\(name.rawValue).unrelated"), object: "wrong-name")
        center.post(name: name, object: "first")
        try await self.waitForDelivery(until: { !received.isEmpty })
        #expect(received == ["first"])
        observer = nil
        try await self.waitForDelivery(until: { weakObserver == nil })
        #expect(weakObserver == nil)
        center.post(name: name, object: "after-release")
        try await self.waitForDelivery(until: { received.count > 1 }, timeout: 0.1)
        #expect(received == ["first"])
    }

    private func waitForDelivery(until condition: () -> Bool, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
