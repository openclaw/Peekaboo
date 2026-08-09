import Testing
@testable import PeekabooAutomationKit

struct BoundedAXWindowIdentityScannerTests {
    @Test
    func `many-child scan stops at aggregate deadline and resets each child timeout`() {
        var remainingTimeouts: [Float?] = [0.1, 0.04, nil]
        var probed: [Int] = []
        var timeoutEvents: [(Int, Float)] = []

        let result = BoundedAXWindowIdentityScanner.scanWindows(
            Array(0..<100),
            remainingTimeout: { remainingTimeouts.removeFirst() },
            applyTimeout: { window, timeout in timeoutEvents.append((window, timeout)) },
            snapshot: { window in
                probed.append(window)
                return nil
            })

        #expect(result == nil)
        #expect(probed == [0, 1])
        #expect(timeoutEvents.map(\.0) == [0, 0, 1, 1])
        #expect(timeoutEvents.map(\.1) == [0.1, 0, 0.04, 0])
        #expect(remainingTimeouts.isEmpty)
        #expect(BoundedAXWindowIdentityScanner.callTimeout(remainingSeconds: 0) == nil)
        #expect(BoundedAXWindowIdentityScanner.callTimeout(remainingSeconds: 0.004) == 0.004)
        #expect(BoundedAXWindowIdentityScanner.callTimeout(remainingSeconds: 0.04) == 0.04)
        #expect(BoundedAXWindowIdentityScanner.callTimeout(remainingSeconds: 1) == 0.1)
    }
}
