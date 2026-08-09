import AppKit
import SwiftUI

/// Captures the NSWindow hosting a SwiftUI fixture without relying on `NSApp.keyWindow`.
/// A background app intentionally has no key window, but AppKit can still attach a sheet to its
/// owning window without activating the application.
struct OwningWindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> WindowReferenceView {
        let view = WindowReferenceView()
        view.onWindowChange = { self.window = $0 }
        return view
    }

    func updateNSView(_ nsView: WindowReferenceView, context: Context) {
        nsView.onWindowChange = { self.window = $0 }
    }

    final class WindowReferenceView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            self.onWindowChange?(self.window)
        }
    }
}
