import ApplicationServices
import Foundation

/// Outcome of an accessibility action issued off the caller's actor.
enum DetachedAXActionOutcome: Equatable, Sendable {
    /// The AX call returned within the grace period.
    case completed(AXError)
    /// The AX call did not return within the grace period and keeps running detached.
    ///
    /// For actions such as `AXShowMenu` this is the *success* signal: the target app is pumping a
    /// nested menu-tracking runloop and `AXUIElementPerformAction` will not return until the menu
    /// is dismissed. Waiting for it would block the caller (and, for bridge hosts, every other
    /// client) for the lifetime of the menu.
    case stillRunning
}

/// Runs blocking accessibility calls on a dedicated thread so callers can report success promptly.
///
/// `AXUIElementPerformAction` is synchronous and can block for arbitrarily long when the action
/// starts a nested runloop in the target app (context menus, modal panels). The AX C API is
/// documented thread-safe, so the call is issued from a detached thread and raced against a grace
/// period. If the call is still running when the grace period elapses, the action is considered
/// delivered and the thread is left to finish on its own; its eventual result is discarded.
enum DetachedAXActionRunner {
    /// Grace period for `AXShowMenu`: genuine failures return within a few milliseconds, while a
    /// successfully opened menu blocks until dismissal.
    static let showMenuGracePeriod: TimeInterval = 0.5

    /// Grace period for `AXPress`: presses normally return quickly, but a press that opens a
    /// modal loop should still be reported as delivered.
    static let pressGracePeriod: TimeInterval = 2.0

    static func perform(
        action actionName: String,
        on element: AXUIElement,
        gracePeriod: TimeInterval) async -> DetachedAXActionOutcome
    {
        let box = UncheckedAXElementBox(element: element)
        return await self.run(gracePeriod: gracePeriod) {
            AXUIElementPerformAction(box.element, actionName as CFString)
        }
    }

    /// Runs `operation` on a detached thread, resolving with `.stillRunning` if it does not
    /// return within `gracePeriod`. Factored over a closure so tests can exercise the race
    /// without a live accessibility element.
    static func run(
        gracePeriod: TimeInterval,
        operation: @escaping @Sendable () -> AXError) async -> DetachedAXActionOutcome
    {
        let gate = OneShotOutcomeGate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<
            DetachedAXActionOutcome,
            Never,
        >) in
            gate.install(continuation)
            Thread.detachNewThread {
                let result = operation()
                gate.resume(with: .completed(result))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + gracePeriod) {
                gate.resume(with: .stillRunning)
            }
        }
    }
}

/// AXUIElement is a CF type and the accessibility API is documented thread-safe, but the type is
/// not annotated Sendable; this box states that contract explicitly.
private struct UncheckedAXElementBox: @unchecked Sendable {
    let element: AXUIElement
}

/// Resumes a continuation exactly once, whichever of the racing callbacks fires first.
private final class OneShotOutcomeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DetachedAXActionOutcome, Never>?

    func install(_ continuation: CheckedContinuation<DetachedAXActionOutcome, Never>) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.continuation = continuation
    }

    func resume(with outcome: DetachedAXActionOutcome) {
        self.lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.lock.unlock()
        continuation?.resume(returning: outcome)
    }
}
