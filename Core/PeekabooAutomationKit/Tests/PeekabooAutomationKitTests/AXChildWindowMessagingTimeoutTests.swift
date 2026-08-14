import ApplicationServices
import AXorcist
import Darwin
import Testing
@testable import PeekabooAutomationKit

struct AXChildWindowMessagingTimeoutTests {
    @Test
    @MainActor
    func `checked path refuses the child read when deadline setup fails`() {
        let invalidApplication = Element(AXUIElementCreateApplication(-1))
        var readCount = 0

        #expect(throws: AXMessagingTimeoutError.systemFailure(code: AXError.invalidUIElement.rawValue)) {
            try AXChildWindowMessagingTimeout.performChecked(
                on: invalidApplication,
                timeout: 0.25)
            { _ in
                readCount += 1
            }
        }

        #expect(readCount == 0)
    }

    @Test
    @MainActor
    func `checked optional caller returns nil without dispatching the read`() {
        let invalidApplication = Element(AXUIElementCreateApplication(-1))
        var readCount = 0

        let value = try? AXChildWindowMessagingTimeout.performChecked(
            on: invalidApplication,
            timeout: 0.25)
        { _ in
            readCount += 1
            return 42
        }

        #expect(value == nil)
        #expect(readCount == 0)
    }

    @Test
    @MainActor
    func `checked path releases its scope after error and cancellation`() throws {
        let application = Element(AXUIElementCreateApplication(getpid()))

        #expect(throws: TimeoutProbeError.self) {
            try AXChildWindowMessagingTimeout.performChecked(on: application, timeout: 0.25) { _ in
                throw TimeoutProbeError.failed
            }
        }
        #expect(throws: CancellationError.self) {
            try AXChildWindowMessagingTimeout.performChecked(on: application, timeout: 0.25) { _ in
                throw CancellationError()
            }
        }

        let value = try AXChildWindowMessagingTimeout.performChecked(
            on: application,
            timeout: 0.25,
            operation: { _ in 42 })
        #expect(value == 42)
    }

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
