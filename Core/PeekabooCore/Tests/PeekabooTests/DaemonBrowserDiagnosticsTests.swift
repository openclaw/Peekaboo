import Foundation
import PeekabooBridge
import Testing
@testable import PeekabooCore

@MainActor
struct DaemonBrowserDiagnosticsTests {
    @Test(arguments: [false, true])
    func `health returns while discovery is blocked and preserves cached diagnostics`(connected: Bool) async throws {
        let cache = DaemonBrowserDiagnostics()
        let gate = DiagnosticGate()
        let receipt = connected ? PeekabooBridgeBrowserConnectionReceipt(browserURL: "http://127.0.0.1:9222/") : nil
        let epoch = connected ? UUID() : nil
        let discovered = connected ? [PeekabooBridgeBrowserInfo(
            name: "Fixture Chrome",
            bundleIdentifier: "com.google.Chrome",
            processIdentifier: 42,
            version: "151",
            channel: "stable")] : []
        let expected = PeekabooBridgeBrowserStatus(
            isConnected: connected,
            toolCount: connected ? 29 : 0,
            detectedBrowsers: discovered,
            connectionReceipt: receipt,
            providerSessionEpoch: epoch,
            observation: .confirmed)
        var calls = 0
        let read: @MainActor @Sendable () async -> PeekabooBridgeBrowserStatus = {
            calls += 1
            await gate.block()
            return expected
        }

        let initial = cache.snapshot(read: read)
        #expect(initial.observation == .indeterminate)
        #expect(initial.error?.contains("have not completed") == true)
        await gate.waitUntilBlocked()
        for _ in 0..<20 {
            #expect(cache.snapshot(read: read).observation == .indeterminate)
        }
        #expect(calls == 1)
        await gate.release()
        // Wait for publication without exposing the owner's refresh task to tests.
        var cached = initial
        for _ in 0..<1000 {
            await Task.yield()
            cached = cache.snapshot(read: read)
            if cached.error?.contains("Cached browser diagnostics") == true {
                break
            }
        }
        #expect(cached.observation == .indeterminate)
        #expect(cached.error?.contains("Cached browser diagnostics") == true)
        #expect(cached.isConnected == expected.isConnected)
        #expect(cached.toolCount == expected.toolCount)
        #expect(cached.detectedBrowsers == expected.detectedBrowsers)
        #expect(cached.connectionReceipt == expected.connectionReceipt)
        #expect(cached.providerSessionEpoch == epoch)
        let data = try JSONEncoder.peekabooBridgeEncoder().encode(cached)
        #expect(try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeBrowserStatus.self, from: data) == cached)
        for _ in 0..<1000 {
            await Task.yield()
            cached = cache.snapshot { throw DiagnosticFailure() }
            if cached.error == "Fixture discovery unavailable" {
                break
            }
        }
        #expect(cached.error == "Fixture discovery unavailable")
        #expect(cached.observation == .indeterminate)
        #expect(cached.isConnected == expected.isConnected)
        #expect(cached.detectedBrowsers == expected.detectedBrowsers)
        #expect(cached.connectionReceipt == expected.connectionReceipt)
        cache.stop()
        await gate.release()
    }

    @Test
    func `stopped diagnostics never start optional work`() {
        let cache = DaemonBrowserDiagnostics()
        cache.stop()
        let result = cache.snapshot {
            Issue.record("Stopped daemon must not refresh browser diagnostics")
            return .init(isConnected: false, toolCount: 0, detectedBrowsers: [])
        }
        #expect(result.observation == .indeterminate)
    }
}

private struct DiagnosticFailure: LocalizedError {
    var errorDescription: String? {
        "Fixture discovery unavailable"
    }
}

private actor DiagnosticGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var released = false

    func block() async {
        guard !self.released else { return }
        await withCheckedContinuation { continuation in
            self.waiting = continuation
            self.entered?.resume()
            self.entered = nil
        }
    }

    func waitUntilBlocked() async {
        guard self.waiting == nil else { return }
        await withCheckedContinuation { self.entered = $0 }
    }

    func release() {
        self.released = true
        self.waiting?.resume()
        self.waiting = nil
    }
}
