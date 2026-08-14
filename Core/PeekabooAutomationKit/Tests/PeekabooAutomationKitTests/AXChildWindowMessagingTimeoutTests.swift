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

        #expect(throws: AXChildWindowMessagingTimeoutError.setupFailure(code: AXError.invalidUIElement.rawValue)) {
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
    func `checked scope resets after errors and cancellation`() {
        let probe = TimeoutProbe()

        #expect(throws: TimeoutProbeError.self) {
            try AXChildWindowMessagingTimeout.performChecked(
                timeout: 0.25,
                applyTimeout: probe.applyChecked)
            {
                throw TimeoutProbeError.failed
            }
        }
        #expect(throws: CancellationError.self) {
            try AXChildWindowMessagingTimeout.performChecked(
                timeout: 0.5,
                applyTimeout: probe.applyChecked)
            {
                throw CancellationError()
            }
        }

        #expect(probe.history == [0.25, 0, 0.5, 0])
    }

    @Test
    func `checked scope surfaces reset failure`() {
        var timeoutHistory: [Float] = []

        #expect(throws: AXChildWindowMessagingTimeoutError.resetFailure(code: AXError.failure.rawValue)) {
            try AXChildWindowMessagingTimeout.performChecked(
                timeout: 0.25,
                applyTimeout: { timeout in
                    timeoutHistory.append(timeout)
                    return timeout == 0 ? .failure : .success
                },
                operation: { 42 })
        }

        #expect(timeoutHistory == [0.25, 0])
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
    @MainActor
    func `equal elements with distinct references keep independent scopes`() throws {
        let first = Element(AXUIElementCreateApplication(getpid()))
        let second = Element(AXUIElementCreateApplication(getpid()))
        #expect(first == second)
        #expect(ObjectIdentifier(first.underlyingElement) != ObjectIdentifier(second.underlyingElement))

        let value = try AXChildWindowMessagingTimeout.performChecked(on: first, timeout: 0.25) { _ in
            try AXChildWindowMessagingTimeout.performChecked(on: second, timeout: 0.25) { _ in 42 }
        }
        #expect(value == 42)
    }

    @Test
    @MainActor
    func `distinct system-wide references share one scope`() throws {
        let first = Element(AXUIElementCreateSystemWide())
        let second = Element(AXUIElementCreateSystemWide())
        #expect(ObjectIdentifier(first.underlyingElement) != ObjectIdentifier(second.underlyingElement))

        _ = try AXChildWindowMessagingTimeout.performChecked(on: first, timeout: 0.25) { _ in
            #expect(throws: AXChildWindowMessagingTimeoutError.nestedScope) {
                try AXChildWindowMessagingTimeout.performChecked(on: second, timeout: 0.25) { _ in
                    Issue.record("The nested system-wide operation must not run")
                }
            }
        }
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

    func applyChecked(_ timeout: Float) -> AXError {
        self.apply(timeout)
        return .success
    }
}
