import Testing
@testable import PeekabooFoundation

/// Guards the pre-dispatch classification used by snapshot invalidation bookkeeping.
///
/// The hazard: the same error case can be thrown from a pre-dispatch lookup AND a post-dispatch
/// path (e.g. `.menuNotFound` is thrown by a Dock right-click *after* the menu-opening click).
/// Only cases that are pre-dispatch at every throw site may return `true`.
struct PeekabooErrorDispatchClassificationTests {
    @Test
    func `Target-lookup failures are classified pre-dispatch`() {
        #expect(PeekabooError.elementNotFound("B1").failedBeforeDispatchingDesktopEvent)
        #expect(PeekabooError.snapshotNotFound("123").failedBeforeDispatchingDesktopEvent)
        #expect(PeekabooError.snapshotNotAvailable("no snapshot").failedBeforeDispatchingDesktopEvent)
        #expect(PeekabooError.sessionNotFound("s1").failedBeforeDispatchingDesktopEvent)
    }

    @Test
    func `Menu-lookup failures are not pre-dispatch because Dock right-click throws them post-click`() {
        // Regression: `dock right-click --select ...` right-clicks the item, opens the context
        // menu, then throws `.menuNotFound` when the item is absent -- the menu is on screen.
        #expect(!PeekabooError.menuNotFound("Finder").failedBeforeDispatchingDesktopEvent)
        #expect(!PeekabooError.menuItemNotFound("New Finder Window").failedBeforeDispatchingDesktopEvent)
    }

    @Test
    func `Errors reachable after an event was dispatched are not pre-dispatch`() {
        // `.snapshotStale` is raised by `normalizingSnapshotErrors` wrapping the action itself.
        #expect(!PeekabooError.snapshotStale("target element is no longer available")
            .failedBeforeDispatchingDesktopEvent)
        #expect(!PeekabooError.timeout("clicking").failedBeforeDispatchingDesktopEvent)
        #expect(!PeekabooError.clickFailed("dispatch").failedBeforeDispatchingDesktopEvent)
        #expect(!PeekabooError.typeFailed("dispatch").failedBeforeDispatchingDesktopEvent)
        #expect(!PeekabooError.invalidInput("bad").failedBeforeDispatchingDesktopEvent)
        #expect(!PeekabooError.invalidCoordinates.failedBeforeDispatchingDesktopEvent)
        #expect(!PeekabooError.permissionDeniedEventSynthesizing.failedBeforeDispatchingDesktopEvent)
        #expect(!PeekabooError.windowNotFound(criteria: "x").failedBeforeDispatchingDesktopEvent)
        #expect(!PeekabooError.appNotFound("Foo").failedBeforeDispatchingDesktopEvent)
    }
}
