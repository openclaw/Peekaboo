---
summary: 'Swift and SwiftUI conventions for Peekaboo source changes.'
read_when:
  - 'adding or refactoring Swift and SwiftUI code'
---

# Swift conventions

Peekaboo uses Swift 6.2 conventions and explicit `self` for member references. Run the repository's SwiftFormat and
SwiftLint commands, and preserve the declared package and app floors in [platform support](platform-support.md).
Do not raise a deployment target to make a refactor compile.

## State and views

Keep view-local values in `@State`, pass writable values through `@Binding`, and use the existing environment or
initializer injection for shared dependencies. New observable reference models can use Observation with `@Observable`;
isolate UI-owned models to `@MainActor` and let the owning view retain them through `@State`. Use `@Bindable` where a
child needs bindings to an observable model's properties.

Keep state near its owner. Extract a model when it owns shared state or behavior, and extract a view when it gives a
subtree a clear responsibility. A small view does not need a matching model type. Preserve established public
`ObservableObject` contracts unless the change explicitly migrates their callers.

Keep rendering code free of I/O and repeated expensive work. Use `.task` for asynchronous work tied to a view's lifetime;
use `.task(id:)` when a specific input should restart it. Handle cancellation separately from a user-visible failure.
Use `TimelineView` for new time-driven presentation when its scheduling semantics fit the feature; retain event streams
when the stream itself is the source of truth.

## Concurrency and service boundaries

Respect actor isolation instead of adding `nonisolated(unsafe)` or `@unchecked Sendable` to silence the compiler.
When a type uses a lock or queue to protect shared state, keep every access within that synchronization boundary and
document why an unchecked conformance is sound. Prefer typed, `Sendable` values across actor and transport boundaries.

An `async` function does not make a blocking Accessibility or socket call nonblocking. Use the existing bounded native
workers and transport queues at those boundaries. Cancellation can end the caller's wait without stopping native work;
preserve the worker's admission, deadline, and cleanup rules. See [architecture](ARCHITECTURE.md) for ownership and
[error handling](error-handling-guide.md) for result propagation.

Prefer structured concurrency for child work whose lifetime belongs to the caller. Detached tasks need an explicit
lifetime and cancellation owner. Keep production automation in AutomationKit, agent/MCP adaptation in AgentRuntime,
and shared visual components in UICore or Visualizer.

## Verification

Exercise behavior at its owning boundary. Use injected clocks, services, and temporary stores where those seams already
exist; await observable completion instead of sleeping for an estimated duration. Preserve tests for released APIs and
wire formats during refactors. [Lint compatibility](dev/lint-compatibility.md) records the narrow existing exceptions.

Build the affected package and run its relevant tests. For UI behavior, also run the built app against a controlled
fixture and verify the visible result. SwiftUI previews help with layout, but do not establish lifecycle, permission,
or automation correctness. Follow [building](building.md) and the relevant `docs/testing/` contract for those checks.
