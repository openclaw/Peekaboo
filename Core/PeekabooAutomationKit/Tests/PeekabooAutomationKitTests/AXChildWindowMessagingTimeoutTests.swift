import Testing
@testable import PeekabooAutomationKit

struct AXChildWindowMessagingTimeoutTests {
    @Test
    func `exact resolution arms child timeout before an unresponsive ID probe`() {
        let probe = TimeoutProbe()

        let resolved: Int? = AXChildWindowMessagingTimeout.perform(
            timeout: 0.1,
            applyTimeout: probe.apply)
        {
            #expect(probe.current == 0.1)
            return nil
        }

        #expect(resolved == nil)
        #expect(probe.history == [0.1, 0])
    }

    @Test
    func `close arms child timeout before an unresponsive action`() {
        let probe = TimeoutProbe()

        let dispatched = AXChildWindowMessagingTimeout.perform(
            timeout: 0.75,
            applyTimeout: probe.apply)
        {
            #expect(probe.current == 0.75)
            return false
        }

        #expect(!dispatched)
        #expect(probe.history == [0.75, 0])
    }

    @Test
    func `maximize clears child timeout after a failing bounds probe`() {
        let probe = TimeoutProbe()

        #expect(throws: TimeoutProbeError.self) {
            try AXChildWindowMessagingTimeout.perform(
                timeout: 0.75,
                applyTimeout: probe.apply)
            {
                #expect(probe.current == 0.75)
                throw TimeoutProbeError.failed
            }
        }

        #expect(probe.history == [0.75, 0])
    }
}

private enum TimeoutProbeError: Error {
    case failed
}

private final class TimeoutProbe {
    private(set) var current: Float = 0
    private(set) var history: [Float] = []

    func apply(_ timeout: Float) {
        self.current = timeout
        self.history.append(timeout)
    }
}
