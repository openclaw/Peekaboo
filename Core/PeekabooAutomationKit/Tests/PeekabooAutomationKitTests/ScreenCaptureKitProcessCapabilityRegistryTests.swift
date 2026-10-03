import Darwin
import Foundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
struct ScreenCaptureKitProcessCapabilityRegistryTests {
    private typealias Registry = ScreenCaptureKitProcessCapabilityRegistry

    @Test(arguments: [[], [0, -1, 999]] as [[pid_t]])
    func `Empty census never invokes inspection`(processIdentifiers: [pid_t]) {
        let rows = Registry.collectProcessCensus(in: processIdentifiers, excluding: 999) { _ in
            Issue.record("An excluded process reached inspection")
            return nil
        }
        #expect(rows.isEmpty)
    }

    @Test
    func `Census visits each eligible PID once and retains every completed row`() {
        let observations = CensusObservations()
        let rows = Registry.collectProcessCensus(in: [9, 4, 9, 999, 0, -1, 7, 4, 8], excluding: 999) { pid in
            observations.begin(pid)
            defer { observations.end() }
            return pid == 7 ? nil : Self.row(pid, blocker: pid != 8)
        }

        #expect(observations.snapshot.visited.sorted() == [4, 7, 8, 9])
        #expect(rows.map(\.key.processIdentifier).sorted() == [4, 8, 9])
        #expect(rows.compactMap(\.conflict).map(\.processIdentifier).sorted() == [4, 9])
        #expect(observations.snapshot.peak <= 2)
    }

    @Test
    func `Overlapping censuses share exactly two inspection slots`() throws {
        let observations = CensusObservations()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let completed = DispatchGroup()
        defer {
            for _ in 0..<4 {
                release.signal()
            }
        }

        let censuses: [[pid_t]] = [[11, 12], [21, 22]]
        for identifiers in censuses {
            completed.enter()
            DispatchQueue.global().async {
                defer { completed.leave() }
                started.signal()
                let rows = Registry.collectProcessCensus(in: identifiers, excluding: 999) { pid in
                    observations.begin(pid)
                    defer { observations.end() }
                    entered.signal()
                    #expect(release.wait(timeout: .now() + 5) == .success)
                    return Self.row(pid, blocker: true)
                }
                observations.finish(rows)
            }
        }

        for _ in 0..<2 {
            try #require(started.wait(timeout: .now() + 5) == .success)
            try #require(entered.wait(timeout: .now() + 5) == .success)
        }
        #expect(observations.snapshot.active == 2)
        #expect(entered.wait(timeout: .now() + 0.1) == .timedOut)
        for _ in 0..<4 {
            release.signal()
        }
        try #require(completed.wait(timeout: .now() + 5) == .success)

        let result = observations.snapshot
        #expect(result.peak == 2)
        #expect(result.active == 0)
        #expect(result.completedCensuses == 2)
        #expect(result.visited.sorted() == [11, 12, 21, 22])
        #expect(result.rows.compactMap(\.conflict).map(\.processIdentifier).sorted() == [11, 12, 21, 22])
    }

    @Test
    func `Delayed final blocker prevents a partial census from reaching its consumer`() throws {
        let observations = CensusObservations()
        let blockerEntered = DispatchSemaphore(value: 0)
        let releaseBlocker = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let nonblockers = DispatchGroup()
        nonblockers.enter()
        nonblockers.enter()
        defer { releaseBlocker.signal() }

        DispatchQueue.global().async {
            let rows = Registry.collectProcessCensus(in: [10, 20, 30], excluding: 999) { pid in
                observations.begin(pid)
                defer { observations.end() }
                if pid == 30 {
                    blockerEntered.signal()
                    #expect(releaseBlocker.wait(timeout: .now() + 5) == .success)
                } else {
                    nonblockers.leave()
                }
                return Self.row(pid, blocker: pid == 30)
            }
            observations.finish(rows)
            completed.signal()
        }

        try #require(blockerEntered.wait(timeout: .now() + 5) == .success)
        try #require(nonblockers.wait(timeout: .now() + 5) == .success)
        #expect(completed.wait(timeout: .now() + 0.1) == .timedOut)
        #expect(observations.snapshot.completedCensuses == 0)
        releaseBlocker.signal()
        try #require(completed.wait(timeout: .now() + 5) == .success)

        let result = observations.snapshot
        #expect(result.completedCensuses == 1)
        #expect(Set(result.rows.map(\.key)) == Set([10, 20, 30].map { Self.row($0, blocker: false).key }))
        let expectedBlocker = try #require(Self.row(30, blocker: true).conflict)
        #expect(result.rows.compactMap(\.conflict) == [expectedBlocker])
    }

    private static func row(_ pid: pid_t, blocker: Bool) -> Registry.ProcessCensusRow {
        let key = Registry.ProcessInspectionKey(
            processIdentifier: pid,
            processStartIdentity: 9001,
            executablePath: "/synthetic/peekaboo")
        return Registry.ProcessCensusRow(
            key: key,
            conflict: blocker ? .init(
                processIdentifier: pid,
                processStartIdentity: key.processStartIdentity,
                executablePath: key.executablePath) : nil)
    }
}

private final class CensusObservations: @unchecked Sendable {
    struct Snapshot {
        var visited: [pid_t] = []
        var active = 0
        var peak = 0
        var completedCensuses = 0
        var rows: [ScreenCaptureKitProcessCapabilityRegistry.ProcessCensusRow] = []
    }

    private let lock = NSLock()
    private var state = Snapshot()

    var snapshot: Snapshot {
        self.lock.withLock { self.state }
    }

    func begin(_ pid: pid_t) {
        self.lock.withLock {
            self.state.visited.append(pid)
            self.state.active += 1
            self.state.peak = max(self.state.peak, self.state.active)
        }
    }

    func end() {
        self.lock.withLock { self.state.active -= 1 }
    }

    func finish(_ rows: [ScreenCaptureKitProcessCapabilityRegistry.ProcessCensusRow]) {
        self.lock.withLock {
            self.state.rows.append(contentsOf: rows)
            self.state.completedCensuses += 1
        }
    }
}
