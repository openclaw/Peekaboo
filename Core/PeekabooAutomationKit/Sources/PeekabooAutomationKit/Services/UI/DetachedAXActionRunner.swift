import ApplicationServices
import AXorcist
import Foundation
import PeekabooFoundation

/// Runs blocking accessibility calls on a dedicated thread so callers can receive delivery evidence promptly.
///
/// `AXUIElementPerformAction` is synchronous and can block for arbitrarily long when the action
/// starts a nested runloop in the target app (context menus, modal panels). The AX C API is
/// documented thread-safe, so the call is issued from a detached thread and raced against a grace
/// period. If the call is still running when the grace period elapses, the action is recorded as
/// dispatched but unverified and the thread is left to finish on its own; its eventual result is
/// discarded.
enum DetachedAXActionRunner {
    private static let delivery = DesktopActionOutcome.Delivery(
        mechanism: .accessibilityAction,
        mode: .background)

    /// Grace period for `AXShowMenu`: genuine failures return within a few milliseconds, while a
    /// successfully opened menu blocks until dismissal.
    static let showMenuGracePeriod: TimeInterval = 0.5

    /// Grace period for `AXPress`: presses normally return quickly, but a press that opens a
    /// modal loop should still be reported as delivered.
    static let pressGracePeriod: TimeInterval = 2.0

    static func perform(
        action actionName: String,
        on element: AXUIElement,
        gracePeriod: TimeInterval) async throws -> DesktopActionOutcome
    {
        let box = UncheckedAXElementBox(element: element)
        return try await self.run(gracePeriod: gracePeriod) {
            AXUIElementPerformAction(box.element, actionName as CFString)
        }
    }

    /// Runs `operation` on a detached thread, resolving with operation-still-running evidence if
    /// it does not return within `gracePeriod`. Factored over a closure so tests can exercise the
    /// race without a live accessibility element.
    static func run(
        gracePeriod: TimeInterval,
        operation: @escaping @Sendable () -> AXError) async throws -> DesktopActionOutcome
    {
        let gate = OneShotOutcomeGate()
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<
            Result<DesktopActionOutcome, AccessibilitySystemError>,
            Never,
        >) in
            gate.install(continuation)
            Thread.detachNewThread {
                let result = operation()
                if result == .success {
                    gate.resume(with: .success(.dispatchedUnverified(
                        delivery: self.delivery,
                        evidence: .deliveryAccepted)))
                } else {
                    gate.resume(with: .failure(AccessibilitySystemError(result)))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + gracePeriod) {
                gate.resume(with: .success(.dispatchedUnverified(
                    delivery: self.delivery,
                    evidence: .operationStillRunning)))
            }
        }
        return try result.get()
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
    private var continuation: CheckedContinuation<
        Result<DesktopActionOutcome, AccessibilitySystemError>,
        Never,
    >?

    func install(_ continuation: CheckedContinuation<
        Result<DesktopActionOutcome, AccessibilitySystemError>,
        Never,
    >) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.continuation = continuation
    }

    func resume(with outcome: Result<DesktopActionOutcome, AccessibilitySystemError>) {
        self.lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.lock.unlock()
        continuation?.resume(returning: outcome)
    }
}
