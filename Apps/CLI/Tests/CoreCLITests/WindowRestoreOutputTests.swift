import CoreGraphics
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@MainActor
struct WindowRestoreOutputTests {
    private let original = ServiceWindowInfo(
        windowID: 101,
        title: "Fixture",
        bounds: CGRect(x: 10, y: 20, width: 640, height: 480),
        isMinimized: true
    )

    @Test
    func `transient post-restore inventory failure preserves successful output`() async {
        let selected = await restoredWindowOutputInfo(original: self.original) {
            throw PeekabooError.windowNotFound(criteria: "windowId 101")
        }

        #expect(selected == self.original)
    }

    @Test
    func `available post-restore inventory replaces stale display metadata`() async {
        let refreshed = ServiceWindowInfo(
            windowID: 101,
            title: "Restored Fixture",
            bounds: self.original.bounds,
            isMinimized: false
        )

        let selected = await restoredWindowOutputInfo(original: self.original) { refreshed }

        #expect(selected == refreshed)
    }
}
