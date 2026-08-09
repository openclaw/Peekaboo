import Foundation
import Testing
@testable import Peekaboo

@Suite(.tags(.unit))
@MainActor
struct AutomationTargetTrackerTests {
    private let start = Date(timeIntervalSince1970: 1000)

    @Test
    func `Display is capped at three targets`() {
        var store = AutomationTargetActivityStore(idleTimeout: 10)

        for processIdentifier in 1...4 {
            store.recordActivity(
                processIdentifier: pid_t(processIdentifier),
                bundleIdentifier: nil,
                name: "App \(processIdentifier)",
                at: self.start.addingTimeInterval(TimeInterval(processIdentifier)))
        }

        #expect(store.activeTargets.map(\.processIdentifier) == [4, 3, 2])
    }

    @Test
    func `Most recently active targets win`() {
        var store = AutomationTargetActivityStore(idleTimeout: 10)
        for processIdentifier in 1...3 {
            store.recordActivity(
                processIdentifier: pid_t(processIdentifier),
                bundleIdentifier: nil,
                name: "App \(processIdentifier)",
                at: self.start.addingTimeInterval(TimeInterval(processIdentifier)))
        }

        store.recordActivity(
            processIdentifier: 1,
            bundleIdentifier: nil,
            name: "App 1",
            at: self.start.addingTimeInterval(4))

        #expect(store.activeTargets.map(\.processIdentifier) == [1, 3, 2])
    }

    @Test
    func `Expired targets are removed and recent overflow returns`() {
        var store = AutomationTargetActivityStore(idleTimeout: 10)
        for processIdentifier in 1...4 {
            store.recordActivity(
                processIdentifier: pid_t(processIdentifier),
                bundleIdentifier: nil,
                name: "App \(processIdentifier)",
                at: self.start.addingTimeInterval(TimeInterval(processIdentifier * 2)))
        }

        store.expireTargets(at: self.start.addingTimeInterval(13))

        #expect(store.activeTargets.map(\.processIdentifier) == [4, 3, 2])
        store.expireTargets(at: self.start.addingTimeInterval(17))
        #expect(store.activeTargets.map(\.processIdentifier) == [4])
    }

    @Test
    func `Disabling clears and blocks activity until reenabled`() {
        var store = AutomationTargetActivityStore(idleTimeout: 10)
        store.recordActivity(
            processIdentifier: 1,
            bundleIdentifier: nil,
            name: "App 1",
            at: self.start)

        store.setEnabled(false)
        #expect(store.activeTargets.isEmpty)
        store.recordActivity(
            processIdentifier: 2,
            bundleIdentifier: nil,
            name: "App 2",
            at: self.start.addingTimeInterval(1))
        #expect(store.activeTargets.isEmpty)

        store.setEnabled(true)
        store.recordActivity(
            processIdentifier: 3,
            bundleIdentifier: nil,
            name: "App 3",
            at: self.start.addingTimeInterval(2))
        #expect(store.activeTargets.map(\.processIdentifier) == [3])
    }
}
