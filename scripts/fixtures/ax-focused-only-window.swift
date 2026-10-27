// Build: mkdir -p .build/fixtures
// swiftc -swift-version 6 scripts/fixtures/ax-focused-only-window.swift -o .build/fixtures/ax-focused-only-window
// Run: .build/fixtures/ax-focused-only-window (prints the PID and exact CGWindowID; Ctrl-C to quit).
import AppKit

@MainActor
final class FocusedOnlyApplication: NSApplication {
    var fixtureWindow: NSWindow?

    override func accessibilityWindows() -> [Any]? {
        []
    }

    override func accessibilityChildren() -> [Any]? {
        []
    }

    override func accessibilityFocusedWindow() -> Any? {
        self.fixtureWindow
    }

    override func accessibilityMainWindow() -> Any? {
        self.fixtureWindow
    }
}

MainActor.assumeIsolated {
    // AppKit traps if a second NSApplication is created; let +sharedApplication instantiate the subclass.
    guard let application = FocusedOnlyApplication.shared as? FocusedOnlyApplication else {
        fatalError("NSApp was created before the fixture application")
    }
    application.setActivationPolicy(.regular)
    let window = NSWindow(
        contentRect: NSRect(x: 200, y: 200, width: 480, height: 220),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false)
    window.title = "AX Focused-Only Window Fixture"
    window.isReleasedWhenClosed = false

    let label = NSTextField(labelWithString: "This window is exposed through AXFocusedWindow and AXMainWindow only.")
    label.maximumNumberOfLines = 2
    label.preferredMaxLayoutWidth = 420
    let field = NSTextField(string: "Fixture text")
    field.setAccessibilityLabel("Fixture Text Field")
    field.widthAnchor.constraint(equalToConstant: 360).isActive = true
    let button = NSButton(title: "Fixture Button", target: nil, action: nil)
    let stack = NSStackView(views: [label, field, button])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 18
    stack.translatesAutoresizingMaskIntoConstraints = false
    window.contentView?.addSubview(stack)
    if let content = window.contentView {
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
    }

    application.fixtureWindow = window
    window.makeKeyAndOrderFront(nil)
    application.activate()
    print("pid=\(ProcessInfo.processInfo.processIdentifier) window_id=\(window.windowNumber)")
    fflush(stdout)
    application.run()
}
