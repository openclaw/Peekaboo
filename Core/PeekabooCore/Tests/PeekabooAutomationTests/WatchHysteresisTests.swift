import CoreGraphics
import Foundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct WatchHysteresisTests {
    @Test
    func `Exits active after quiet period`() {
        // Two frames: first with high delta, second identical.
        let prev = WatchFrameDiffer.LumaBuffer(width: 2, height: 2, pixels: [0, 255, 0, 0])
        let curr = WatchFrameDiffer.LumaBuffer(width: 2, height: 2, pixels: [0, 255, 0, 0])
        let diff = WatchFrameDiffer.computeChange(
            using: .init(
                strategy: .fast,
                diffBudgetMs: nil,
                previous: prev,
                current: curr,
                deltaThreshold: 10,
                originalSize: CGSize(width: 20, height: 20)))
        #expect(diff.changePercent == 0)
    }

    @Test
    func `Exit requires calm for quietMs window`() {
        let nowNs: UInt64 = 1_200_000_000
        let lastActivityNs: UInt64 = 0
        let shouldExit = WatchCaptureActivityPolicy.shouldExitActive(
            changePercent: 0.5,
            threshold: 2.0,
            lastActivityNs: lastActivityNs,
            quietMs: 1000,
            nowNs: nowNs)
        #expect(shouldExit)
    }

    @Test
    func `Stays active when change stays above half-threshold`() {
        let nowNs: UInt64 = 2_000_000_000
        let lastActivityNs: UInt64 = 0
        let shouldExit = WatchCaptureActivityPolicy.shouldExitActive(
            changePercent: 1.2, // >= threshold/2 when threshold is 2.0
            threshold: 2.0,
            lastActivityNs: lastActivityNs,
            quietMs: 500,
            nowNs: nowNs)
        #expect(!shouldExit)
    }

    @Test
    func `Stays active until quietMs elapses`() {
        let nowNs: UInt64 = 300_000_000
        let lastActivityNs: UInt64 = 0
        let shouldExit = WatchCaptureActivityPolicy.shouldExitActive(
            changePercent: 0.1,
            threshold: 1.0,
            lastActivityNs: lastActivityNs,
            quietMs: 1000,
            nowNs: nowNs)
        #expect(!shouldExit)
    }

    @Test
    func `Idle → active → idle timeline honors quiet window`() {
        var lastActivityNs: UInt64 = 0
        var active = false
        let threshold = 2.0
        let quietMs = 800

        func step(change: Double, deltaMs: Int) {
            let nowNs = UInt64(deltaMs) * 1_000_000
            let enter = change >= threshold
            if enter {
                active = true
                lastActivityNs = nowNs
            }
            let shouldExit = active && WatchCaptureActivityPolicy.shouldExitActive(
                changePercent: change,
                threshold: threshold,
                lastActivityNs: lastActivityNs,
                quietMs: quietMs,
                nowNs: nowNs)
            if shouldExit {
                active = false
            }
        }

        // Idle period with small jitter: stay idle.
        step(change: 0.3, deltaMs: 100)
        #expect(!active)

        // Motion spike: enter active.
        step(change: 4.0, deltaMs: 200)
        #expect(active)

        // Mild movement above half-threshold: remain active.
        step(change: 1.2, deltaMs: 500)
        #expect(active)

        // Quiet but not enough time elapsed: still active.
        step(change: 0.1, deltaMs: 900)
        #expect(active)

        // Quiet long enough: exit to idle.
        step(change: 0.1, deltaMs: 1200)
        #expect(!active)
    }
}
