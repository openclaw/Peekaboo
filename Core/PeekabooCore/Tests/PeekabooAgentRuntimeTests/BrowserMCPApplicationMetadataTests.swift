import Dispatch
import Foundation
import Testing
@testable import PeekabooAgentRuntime

@Suite(.serialized)
struct BrowserMCPApplicationMetadataTests {
    @Test
    @MainActor
    func `connection deadline finishes while a metadata callback remains blocked`() async {
        let fixture = MetadataReadFixture()
        let task = Task {
            try await BrowserMCPConnectionDeadline.run(until: .now.advanced(by: .milliseconds(20))) {
                try await BrowserMCPApplicationMetadata.read {
                    fixture.begin()
                    fixture.release.wait()
                    return 42
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { fixture.releaseForFallback() }
        do {
            _ = try await task.value
            Issue.record("A blocked metadata read escaped its connection deadline")
        } catch BrowserMCPConnectionDeadlineError.timedOut {
            #expect(!fixture.wasReleasedForFallback)
        } catch {
            Issue.record(error)
        }
        fixture.release.signal()
        _ = try? await BrowserMCPApplicationMetadata.read { 73 }
    }

    @Test
    func `cancellation releases a running metadata reader and ignores its late value`() async throws {
        let fixture = MetadataReadFixture()
        let task = Task {
            try await BrowserMCPApplicationMetadata.read {
                fixture.begin()
                fixture.release.wait()
                return 42
            }
        }
        await fixture.waitUntilStarted()
        // Keep a failing regression bounded even if the reader stops honoring cancellation.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { fixture.release.signal() }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("A canceled metadata reader returned a value")
        } catch is CancellationError {
            // Returning now must not depend on the synchronous metadata callback finishing.
        }
        fixture.release.signal()
        let next = try await BrowserMCPApplicationMetadata.read { 73 }
        #expect(next == 73)
    }

    @Test
    func `an already canceled metadata read does not enter its callback`() async {
        let fixture = MetadataReadFixture()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await BrowserMCPApplicationMetadata.read {
                fixture.begin()
                return 42
            }
        }
        do {
            _ = try await task.value
            Issue.record("An already canceled metadata reader returned a value")
        } catch is CancellationError {
            // Cancellation must stop this read before it reaches the callback queue.
        } catch {
            Issue.record(error)
        }
        #expect(!fixture.hasStarted)
    }
}

private final class MetadataReadFixture: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var started = false
    private var ready: CheckedContinuation<Void, Never>?
    private var releasedForFallback = false

    var wasReleasedForFallback: Bool {
        self.lock.withLock { self.releasedForFallback }
    }

    func releaseForFallback() {
        self.lock.withLock { self.releasedForFallback = true }
        self.release.signal()
    }

    var hasStarted: Bool {
        self.lock.withLock { self.started }
    }

    func begin() {
        let ready = self.lock.withLock {
            self.started = true
            defer { self.ready = nil }
            return self.ready
        }
        ready?.resume()
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let started = self.lock.withLock {
                if self.started {
                    return true
                }
                self.ready = continuation
                return false
            }
            if started {
                continuation.resume()
            }
        }
    }
}
