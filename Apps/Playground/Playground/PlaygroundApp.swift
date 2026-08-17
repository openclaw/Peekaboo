import AppKit
import Combine
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "boo.peekaboo.playground", category: "App")
private let clickLogger = Logger(subsystem: "boo.peekaboo.playground", category: "Click")
private let keyLogger = Logger(subsystem: "boo.peekaboo.playground", category: "Key")

@main
struct PlaygroundApp: App {
    @StateObject private var actionLogger = ActionLogger.shared
    @StateObject private var tabRouter = PlaygroundTabRouter()
    @StateObject private var windowObserver: WindowEventObserver
    @State private var eventMonitor: Any?
    private let pointerEventLogSequencer = PointerEventLogSequencer()

    init() {
        let actionLogger = ActionLogger.shared
        self._windowObserver = StateObject(wrappedValue: WindowEventObserver(actionLogger: actionLogger))
        self.setupPointerEventMonitor()
        self.setupGlobalKeyMonitor()
    }

    private func setupPointerEventMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: PointerEventLogContract.eventMask) { event in
            self.handlePointerEvent(event)
        }
    }

    private func handlePointerEvent(_ event: NSEvent) -> NSEvent {
        guard let contract = PointerEventLogContract.resolve(
            eventType: event.type,
            buttonNumber: event.buttonNumber),
            let window = event.window,
            let record = self.pointerEventLogSequencer.next(
                contract: contract,
                windowID: window.windowNumber)
        else {
            return event
        }

        clickLogger.info("\(record.message, privacy: .public)")

        // Don't duplicate log in ActionLogger - let the button handlers do their specific logging
        // This is just for system-level logging
        return event
    }

    private func setupGlobalKeyMonitor() {
        // Monitor key events globally within the app
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            let (eventTypeStr, keyInfo) = self.describeKeyEvent(event)

            let logMessage = "\(eventTypeStr): \(keyInfo) (keyCode: \(event.keyCode))"
            keyLogger.info("\(logMessage, privacy: .public)")

            // Also log to ActionLogger for UI display (only for keyDown events)
            if event.type == .keyDown {
                ActionLogger.shared.log(.keyboard, "Key pressed: \(keyInfo)")
            }

            return event
        }
    }

    private let specialKeyLabels: [UInt16: String] = [
        36: "Return",
        76: "Enter",
        48: "Tab",
        53: "Escape",
        49: "Space",
        51: "Delete",
        117: "Forward Delete",
        123: "Left Arrow",
        124: "Right Arrow",
        125: "Down Arrow",
        126: "Up Arrow",
        115: "Home",
        119: "End",
        116: "Page Up",
        121: "Page Down",
        122: "F1",
        120: "F2",
        99: "F3",
        118: "F4",
        96: "F5",
        97: "F6",
        98: "F7",
        100: "F8",
        101: "F9",
        109: "F10",
        103: "F11",
        111: "F12",
        105: "F13",
        107: "F14",
        113: "F15",
        57: "Caps Lock",
        114: "Help",
        71: "Clear",
    ]

    private func specialKeyName(for keyCode: UInt16) -> String {
        self.specialKeyLabels[keyCode] ?? ""
    }

    private func describeKeyEvent(_ event: NSEvent) -> (String, String) {
        var eventTypeStr: String
        var keyInfo = ""

        switch event.type {
        case .keyDown:
            eventTypeStr = "Key Down"
            keyInfo = self.describeKeyCharacters(event)
        case .keyUp:
            eventTypeStr = "Key Up"
            keyInfo = self.describeKeyCharacters(event)
        case .flagsChanged:
            eventTypeStr = "Modifier Changed"
            keyInfo = self.describeModifierFlags(event.modifierFlags)
        default:
            eventTypeStr = "Unknown"
        }

        return (eventTypeStr, keyInfo)
    }

    private func describeKeyCharacters(_ event: NSEvent) -> String {
        var keyInfo = ""
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            keyInfo = "'\(chars)'"
        }
        let specialKey = self.specialKeyName(for: event.keyCode)
        if !specialKey.isEmpty {
            keyInfo = keyInfo.isEmpty ? specialKey : "\(keyInfo) (\(specialKey))"
        }
        return keyInfo
    }

    private func describeModifierFlags(_ flags: NSEvent.ModifierFlags) -> String {
        var modifiers: [String] = []
        if flags.contains(.command) {
            modifiers.append("⌘ Command")
        }
        if flags.contains(.shift) {
            modifiers.append("⇧ Shift")
        }
        if flags.contains(.option) {
            modifiers.append("⌥ Option")
        }
        if flags.contains(.control) {
            modifiers.append("⌃ Control")
        }
        if flags.contains(.function) {
            modifiers.append("fn Function")
        }
        return modifiers.isEmpty ? "Released" : modifiers.joined(separator: " + ")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(self.actionLogger)
                .environmentObject(self.tabRouter)
                .frame(minWidth: 1200, minHeight: 800)
        }
        .windowResizability(.contentSize)
        .commands {
            FixtureCommands()

            CommandGroup(replacing: .appInfo) {
                Button("About Peekaboo Playground") {
                    logger.info("About menu clicked")
                    self.actionLogger.log(.menu, "About menu clicked")
                }
            }

            CommandMenu("Test Menu") {
                Button("Test Action 1") {
                    logger.info("Test Action 1 clicked")
                    self.actionLogger.log(.menu, "Test Action 1 clicked")
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("Test Action 2") {
                    logger.info("Test Action 2 clicked")
                    self.actionLogger.log(.menu, "Test Action 2 clicked")
                }
                .keyboardShortcut("2", modifiers: [.command])

                Divider()

                Menu("Submenu") {
                    Button("Nested Action A") {
                        logger.info("Nested Action A clicked")
                        self.actionLogger.log(.menu, "Submenu > Nested Action A clicked")
                    }

                    Button("Nested Action B") {
                        logger.info("Nested Action B clicked")
                        self.actionLogger.log(.menu, "Submenu > Nested Action B clicked")
                    }
                }

                Divider()

                Button("Disabled Action") {
                    logger.info("This should not be logged - disabled")
                }
                .disabled(true)

                Divider()

                Button("Switch to Click Testing Tab") {
                    self.tabRouter.selectedTab = "click"
                    self.actionLogger.log(.menu, "Switched to tab: Click Testing")
                }
                .keyboardShortcut("1", modifiers: [.command, .option])

                Button("Switch to Text Input Tab") {
                    self.tabRouter.selectedTab = "text"
                    self.actionLogger.log(.menu, "Switched to tab: Text Input")
                }
                .keyboardShortcut("2", modifiers: [.command, .option])

                Button("Switch to Controls Tab") {
                    self.tabRouter.selectedTab = "controls"
                    self.actionLogger.log(.menu, "Switched to tab: Controls")
                }
                .keyboardShortcut("3", modifiers: [.command, .option])

                Button("Switch to Scroll & Gestures Tab") {
                    self.tabRouter.selectedTab = "scroll"
                    self.actionLogger.log(.menu, "Switched to tab: Scroll & Gestures")
                }
                .keyboardShortcut("4", modifiers: [.command, .option])

                Button("Switch to Window Tab") {
                    self.tabRouter.selectedTab = "window"
                    self.actionLogger.log(.menu, "Switched to tab: Window")
                }
                .keyboardShortcut("5", modifiers: [.command, .option])

                Button("Switch to Drag & Drop Tab") {
                    self.tabRouter.selectedTab = "drag"
                    self.actionLogger.log(.menu, "Switched to tab: Drag & Drop")
                }
                .keyboardShortcut("6", modifiers: [.command, .option])

                Button("Switch to Keyboard Tab") {
                    self.tabRouter.selectedTab = "keyboard"
                    self.actionLogger.log(.menu, "Switched to tab: Keyboard")
                }
                .keyboardShortcut("7", modifiers: [.command, .option])
            }

            CommandGroup(after: .textEditing) {
                Button("Clear All Logs") {
                    logger.info("Clear logs menu clicked")
                    self.actionLogger.clearLogs()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }

        WindowGroup("Click Fixture", id: "fixture-click") {
            ClickTestingView()
                .environmentObject(self.actionLogger)
                .frame(minWidth: 1200, minHeight: 800)
        }
        .windowResizability(.contentSize)

        WindowGroup("Text Fixture", id: "fixture-text") {
            TextInputView()
                .environmentObject(self.actionLogger)
                .frame(minWidth: 1200, minHeight: 800)
        }
        .windowResizability(.contentSize)

        WindowGroup("Controls Fixture", id: "fixture-controls") {
            ControlsView()
                .environmentObject(self.actionLogger)
                .frame(minWidth: 1200, minHeight: 800)
        }
        .windowResizability(.contentSize)

        WindowGroup("Dialog Fixture", id: "fixture-dialog") {
            DialogFixtureView()
                .environmentObject(self.actionLogger)
                .frame(minWidth: 1200, minHeight: 800)
        }
        .windowResizability(.contentSize)

        WindowGroup("Scroll Fixture", id: "fixture-scroll") {
            ScrollTestingView()
                .environmentObject(self.actionLogger)
                .frame(minWidth: 1200, minHeight: 800)
        }
        .windowResizability(.contentSize)

        WindowGroup("Window Fixture", id: "fixture-window") {
            WindowTestingView()
                .environmentObject(self.actionLogger)
                .environmentObject(self.tabRouter)
                .frame(minWidth: 1200, minHeight: 800)
        }
        .windowResizability(.automatic)

        WindowGroup("Drag Fixture", id: "fixture-drag") {
            DragDropView()
                .environmentObject(self.actionLogger)
                .frame(minWidth: 1200, minHeight: 800)
        }
        .windowResizability(.contentSize)

        WindowGroup("Keyboard Fixture", id: "fixture-keyboard") {
            KeyboardView()
                .environmentObject(self.actionLogger)
                .frame(minWidth: 1200, minHeight: 800)
        }
        .windowResizability(.contentSize)

        WindowGroup("Log Viewer", id: "log-viewer") {
            LogViewerWindow()
                .environmentObject(self.actionLogger)
        }
        .windowResizability(.contentSize)
    }
}
