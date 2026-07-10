import CoreGraphics
import PeekabooCore
import Testing
@testable import PeekabooCLI

struct FocusTargetResolverTests {
    @Test
    @MainActor
    func `Optional focus lookups propagate cancellation`() async {
        let task = Task { @MainActor in
            try await FocusFailurePolicy.optional {
                withUnsafeCurrentTask { $0?.cancel() }
                return 42
            }
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        await #expect(throws: CancellationError.self) {
            try await FocusFailurePolicy.flatteningOptional { () async throws -> Int? in
                throw CancellationError()
            }
        }
    }

    @Test
    func `explicit windowID always wins`() {
        let snapshot = UIAutomationSnapshot(
            applicationBundleId: "com.example.app",
            windowTitle: "X",
            windowID: 42
        )
        let result = FocusTargetResolver.resolve(
            windowID: 777,
            snapshot: snapshot,
            applicationName: "Safari",
            windowTitle: "GitHub"
        )

        #expect(result == .windowId(777))
    }

    @Test
    func `snapshot windowID wins when present`() {
        let snapshot = UIAutomationSnapshot(
            applicationBundleId: "com.example.app",
            windowTitle: "X",
            windowID: 42
        )
        let result = FocusTargetResolver.resolve(
            windowID: nil,
            snapshot: snapshot,
            applicationName: "Safari",
            windowTitle: "GitHub"
        )

        #expect(result == .windowId(42))
    }

    @Test
    func `snapshot without windowID falls back to bundleId + title`() {
        let snapshot = UIAutomationSnapshot(
            applicationBundleId: "com.example.app",
            windowTitle: "My Window",
            windowID: nil
        )
        let result = FocusTargetResolver.resolve(
            windowID: nil,
            snapshot: snapshot,
            applicationName: nil,
            windowTitle: nil
        )

        #expect(result == .bestWindow(applicationName: "com.example.app", windowTitle: "My Window"))
    }

    @Test
    func `explicit app/title override snapshot metadata when windowID missing`() {
        let snapshot = UIAutomationSnapshot(
            applicationBundleId: "com.example.app",
            windowTitle: "Old Title",
            windowID: nil
        )
        let result = FocusTargetResolver.resolve(
            windowID: nil,
            snapshot: snapshot,
            applicationName: "Safari",
            windowTitle: "GitHub"
        )

        #expect(result == .bestWindow(applicationName: "Safari", windowTitle: "GitHub"))
    }

    @Test
    func `no snapshot, app resolves to best window`() {
        let result = FocusTargetResolver.resolve(
            windowID: nil,
            snapshot: nil,
            applicationName: "Safari",
            windowTitle: nil
        )

        #expect(result == .bestWindow(applicationName: "Safari", windowTitle: nil))
    }

    @Test
    func `no inputs returns nil`() {
        let result = FocusTargetResolver.resolve(
            windowID: nil,
            snapshot: nil,
            applicationName: nil,
            windowTitle: nil
        )

        #expect(result == nil)
    }

    // Remote snapshot stores return nil for getUIAutomationSnapshot, which used to make
    // `--foreground` silently skip focusing. The detection-result window context must resolve
    // a focus target in that case.

    @Test
    func `detection window context windowID resolves when snapshot is unavailable`() {
        let result = FocusTargetResolver.resolve(
            windowID: nil,
            snapshot: nil,
            windowContext: WindowContext(
                applicationName: "Playground",
                applicationBundleId: "boo.peekaboo.playground.debug",
                applicationProcessId: 92941,
                windowTitle: "Playground",
                windowID: 3279
            ),
            applicationName: nil,
            windowTitle: nil
        )

        #expect(result == .windowId(3279))
    }

    @Test
    func `detection window context app resolves best window when windowID missing`() {
        let result = FocusTargetResolver.resolve(
            windowID: nil,
            snapshot: nil,
            windowContext: WindowContext(
                applicationName: "Playground",
                applicationBundleId: "boo.peekaboo.playground.debug",
                windowTitle: "Playground"
            ),
            applicationName: nil,
            windowTitle: nil
        )

        #expect(result == .bestWindow(
            applicationName: "boo.peekaboo.playground.debug",
            windowTitle: "Playground"
        ))
    }

    @Test
    func `explicit windowID still wins over the detection window context`() {
        let result = FocusTargetResolver.resolve(
            windowID: 777,
            snapshot: nil,
            windowContext: WindowContext(windowID: 3279),
            applicationName: nil,
            windowTitle: nil
        )

        #expect(result == .windowId(777))
    }

    @Test
    func `snapshot windowID wins over the detection window context`() {
        let snapshot = UIAutomationSnapshot(
            applicationBundleId: "com.example.app",
            windowTitle: "X",
            windowID: 42
        )
        let result = FocusTargetResolver.resolve(
            windowID: nil,
            snapshot: snapshot,
            windowContext: WindowContext(windowID: 3279),
            applicationName: nil,
            windowTitle: nil
        )

        #expect(result == .windowId(42))
    }

    @Test
    func `out of range context windowID falls back to context app identity`() {
        let result = FocusTargetResolver.resolve(
            windowID: nil,
            snapshot: nil,
            windowContext: WindowContext(
                applicationBundleId: "boo.peekaboo.playground.debug",
                windowID: -1
            ),
            applicationName: nil,
            windowTitle: nil
        )

        #expect(result == .bestWindow(
            applicationName: "boo.peekaboo.playground.debug",
            windowTitle: nil
        ))
    }
}
