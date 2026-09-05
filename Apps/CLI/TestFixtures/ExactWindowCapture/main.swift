import AppKit
import Foundation

@MainActor
final class SyntheticSurface: NSView {
    let isPopup: Bool

    init(frame: NSRect, isPopup: Bool) {
        self.isPopup = isPopup
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isOpaque: Bool {
        true
    }

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        if self.isPopup {
            let splitX = self.bounds.width / 4
            let splitY = self.bounds.height / 3
            let tiles: [(NSRect, NSColor)] = [
                (NSRect(x: 0, y: 0, width: splitX, height: splitY), .red),
                (NSRect(x: splitX, y: 0, width: self.bounds.width - splitX, height: splitY), .green),
                (NSRect(x: 0, y: splitY, width: splitX, height: self.bounds.height - splitY), .blue),
                (NSRect(
                    x: splitX,
                    y: splitY,
                    width: self.bounds.width - splitX,
                    height: self.bounds.height - splitY
                ), .yellow),
            ]
            for (rect, color) in tiles {
                color.setFill()
                rect.fill()
            }
            self.label("POPUP 448 x 240", at: NSPoint(x: 140, y: 140))
        } else {
            NSColor.magenta.setFill()
            self.bounds.fill()
            NSColor.black.setFill()
            for x in stride(from: 0, to: Int(self.bounds.width), by: 100) {
                NSRect(x: x, y: 0, width: 12, height: Int(self.bounds.height)).fill()
            }
            self.label("SYNTHETIC PARENT — MUST NOT FILL POPUP CAPTURE", at: NSPoint(x: 30, y: 40))
        }
    }

    private func label(_ text: String, at point: NSPoint) {
        (text as NSString).draw(at: point, withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .bold),
            .foregroundColor: NSColor.black,
            .backgroundColor: NSColor.white,
        ])
    }
}

@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    let readyURL: URL
    let mode: String
    private var parent: NSWindow?
    private var popup: NSWindow?

    init(readyURL: URL, mode: String) {
        self.readyURL = readyURL
        self.mode = mode
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.screens.first,
              screen.visibleFrame.width >= 1000, screen.visibleFrame.height >= 800
        else {
            fputs("Fixture requires a display with at least 1000 x 800 logical points.\n", stderr)
            NSApp.terminate(nil)
            return
        }
        let frame = NSRect(
            x: screen.visibleFrame.minX + 40,
            y: screen.visibleFrame.maxY - 740,
            width: 900,
            height: 700
        )
        let parent = self.window(frame: frame, isPopup: false)
        let popup = self.window(
            frame: NSRect(x: frame.minX + 173, y: frame.maxY - 113 - 240, width: 448, height: 240),
            isPopup: true
        )
        self.parent = parent
        self.popup = popup
        parent.makeKeyAndOrderFront(nil)
        if self.mode == "sheet" {
            parent.beginSheet(popup)
        } else {
            parent.addChildWindow(popup, ordered: .above)
            popup.orderFront(nil)
        }
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.publishReady(primaryScreen: screen.frame)
        }
    }

    private func window(frame: NSRect, isPopup: Bool) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.title = isPopup ? "Synthetic Exact Popup" : "Synthetic Parent"
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.backgroundColor = isPopup ? .yellow : .magenta
        window.hasShadow = false
        window.contentView = SyntheticSurface(frame: NSRect(origin: .zero, size: frame.size), isPopup: isPopup)
        return window
    }

    private func publishReady(primaryScreen: NSRect) {
        guard let parent, let popup else { return }
        func entry(_ window: NSWindow) -> [String: Any] {
            [
                "window_id": window.windowNumber,
                "bounds": [
                    "x": window.frame.minX,
                    "y": primaryScreen.maxY - window.frame.maxY,
                    "width": window.frame.width,
                    "height": window.frame.height,
                ],
                "backing_scale": window.backingScaleFactor,
            ]
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "mode": self.mode,
                "parent": entry(parent),
                "popup": entry(popup),
            ], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: self.readyURL, options: .withoutOverwriting)
            print("Ready: \(self.readyURL.path)")
            fflush(stdout)
        } catch {
            fputs("Could not create fixture receipt: \(error)\n", stderr)
            NSApp.terminate(nil)
        }
    }
}

@main
enum ExactWindowCaptureFixture {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, ["popup", "sheet"].contains(arguments[1]),
              arguments[2].hasPrefix("/"), !FileManager.default.fileExists(atPath: arguments[2])
        else {
            fputs("Usage: ExactWindowCapture popup|sheet /absolute/new-ready.json\n", stderr)
            exit(2)
        }
        let delegate = FixtureDelegate(readyURL: URL(fileURLWithPath: arguments[2]), mode: arguments[1])
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
