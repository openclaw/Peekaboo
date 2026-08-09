import AppKit
import Combine
import OSLog
import SwiftUI
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "boo.peekaboo.playground", category: "Click")

@MainActor
final class PlaygroundTabRouter: ObservableObject {
    @Published var selectedTab: String = "text"
}

struct ContentView: View {
    @EnvironmentObject var actionLogger: ActionLogger
    @EnvironmentObject var tabRouter: PlaygroundTabRouter
    @State private var selectedTab: String = "text"

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(Color(NSColor.controlBackgroundColor))

            Divider()

            TabView(selection: self.$selectedTab) {
                ClickTestingView()
                    .tabItem { Label("Click Testing", systemImage: "cursorarrow.click") }
                    .tag("click")

                TextInputView()
                    .tabItem { Label("Text Input", systemImage: "textformat") }
                    .tag("text")

                DialogTestingView()
                    .tabItem { Label("Dialogs", systemImage: "questionmark.folder") }
                    .tag("dialogs")

                ControlsView()
                    .tabItem { Label("Controls", systemImage: "slider.horizontal.3") }
                    .tag("controls")

                ScrollTestingView()
                    .tabItem { Label("Scroll & Gestures", systemImage: "scroll") }
                    .tag("scroll")

                WindowTestingView()
                    .tabItem { Label("Window", systemImage: "macwindow") }
                    .tag("window")

                DragDropView()
                    .tabItem { Label("Drag & Drop", systemImage: "hand.draw") }
                    .tag("drag")

                KeyboardView()
                    .tabItem { Label("Keyboard", systemImage: "keyboard") }
                    .tag("keyboard")
            }
            .padding(18)
            .onAppear {
                self.selectedTab = self.tabRouter.selectedTab
            }
            .onChange(of: self.selectedTab) { _, newValue in
                guard self.tabRouter.selectedTab != newValue else { return }
                self.tabRouter.selectedTab = newValue
                self.actionLogger.log(.menu, "Tab changed (selection): \(newValue)")
            }
            .onChange(of: self.tabRouter.selectedTab) { _, newValue in
                guard self.selectedTab != newValue else { return }
                self.selectedTab = newValue
                self.actionLogger.log(.menu, "Tab changed (router): \(newValue)")
            }

            Divider()

            StatusBarView()
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Color(NSColor.controlBackgroundColor))
        }
    }
}

struct HeaderView: View {
    @EnvironmentObject var actionLogger: ActionLogger
    @EnvironmentObject var tabRouter: PlaygroundTabRouter

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Peekaboo Playground")
                    .font(.title2.weight(.semibold))

                Text("Test all Peekaboo automation features")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                MetricPill(
                    value: "\(self.actionLogger.actionCount)",
                    label: "actions",
                    systemImage: "list.bullet.clipboard")

                HStack(spacing: 12) {
                    Button(action: {
                        self.actionLogger.showingLogViewer.toggle()
                    }, label: {
                        Label("View Logs", systemImage: "doc.text.magnifyingglass")
                    })

                    Button(action: {
                        self.actionLogger.copyLogsToClipboard()
                    }, label: {
                        Label("Copy Logs", systemImage: "doc.on.clipboard")
                    })

                    Button(action: {
                        self.actionLogger.clearLogs()
                    }, label: {
                        Label("Clear", systemImage: "trash")
                    })
                    .foregroundColor(.red)

                    Button(action: {
                        self.tabRouter.selectedTab = "drag"
                        self.actionLogger.log(.menu, "Quick switched to Drag & Drop tab")
                    }, label: {
                        Label("Go to Drag & Drop", systemImage: "hand.draw")
                    })
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("nav-drag-tab")

                    Button(action: {
                        self.tabRouter.selectedTab = "dialogs"
                        self.actionLogger.log(.menu, "Quick switched to Dialogs tab")
                    }, label: {
                        Label("Go to Dialogs", systemImage: "questionmark.folder")
                    })
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("nav-dialogs-tab")
                }
                .controlSize(.small)
            }
        }
    }
}

struct StatusBarView: View {
    @EnvironmentObject var actionLogger: ActionLogger
    @EnvironmentObject var tabRouter: PlaygroundTabRouter

    var body: some View {
        HStack(spacing: 10) {
            Label("Last Action:", systemImage: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)

            Text(self.actionLogger.lastAction)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Label(self.tabRouter.selectedTab.capitalized, systemImage: "rectangle.split.3x1")
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)

            Text(Date(), style: .time)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

private struct MetricPill: View {
    let value: String
    let label: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: self.systemImage)
                .foregroundStyle(.secondary)
            Text(self.value)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
            Text(self.label)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5))
    }
}

struct DialogTestingView: View {
    @EnvironmentObject var actionLogger: ActionLogger

    @State private var owningWindow: NSWindow?
    @State private var filename: String = "playground-dialog.txt"
    @State private var content: String = """
    Peekaboo Playground

    This file was created from the Dialogs tab.
    """

    @State private var lastSavedPath: String = "—"
    @State private var lastOpenedPath: String = "—"
    @State private var lastAlertResult: String = "—"

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SectionHeader(title: "Dialogs Testing", icon: "questionmark.folder")

                GroupBox("Save Panel") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Name:")
                                .foregroundColor(.secondary)
                            TextField("Filename", text: self.$filename)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("dialog-filename-field")
                        }

                        TextEditor(text: self.$content)
                            .frame(height: 140)
                            .accessibilityIdentifier("dialog-content-editor")

                        HStack(spacing: 12) {
                            Button("Show Save Panel") {
                                self.showSavePanel(mode: .normal)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("dialog-show-save")

                            Button("Show Save Panel (Overwrite /tmp)") {
                                self.showSavePanel(mode: .overwriteTmp)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("dialog-show-save-overwrite")

                            Button("Show Save Panel (TextEdit-like)") {
                                self.showSavePanel(mode: .textEditLike)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("dialog-show-save-textedit")

                            Spacer()
                        }

                        Divider()

                        HStack {
                            Text("Last saved:")
                                .foregroundColor(.secondary)
                            Text(self.lastSavedPath)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .accessibilityIdentifier("dialog-last-saved-path")
                            Spacer()
                        }
                    }
                }

                GroupBox("Open Panel") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Button("Show Open Panel") {
                                self.showOpenPanel()
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("dialog-show-open")

                            Spacer()
                        }

                        Divider()

                        HStack {
                            Text("Last opened:")
                                .foregroundColor(.secondary)
                            Text(self.lastOpenedPath)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .accessibilityIdentifier("dialog-last-opened-path")
                            Spacer()
                        }
                    }
                }

                GroupBox("Alerts") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Button("Show Alert") {
                                self.showAlert(withTextField: false)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("dialog-show-alert")

                            Button("Show Alert (Text Field)") {
                                self.showAlert(withTextField: true)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("dialog-show-alert-textfield")

                            Spacer()
                        }

                        Divider()

                        HStack {
                            Text("Last alert:")
                                .foregroundColor(.secondary)
                            Text(self.lastAlertResult)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .accessibilityIdentifier("dialog-last-alert-result")
                                .id(self.lastAlertResult)
                            Spacer()
                        }
                    }
                }
            }
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .background(OwningWindowReader(window: self.$owningWindow))
    }

    private enum SavePanelMode {
        case normal
        case overwriteTmp
        case textEditLike
    }

    private func showSavePanel(mode: SavePanelMode) {
        guard let window = self.owningWindow else {
            self.actionLogger.log(.dialog, "Save panel failed", details: "No owning window")
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = self.filename
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.plainText]
        panel.showsTagField = true

        if mode == .textEditLike {
            let formatLabel = NSTextField(labelWithString: "File Format:")
            formatLabel.textColor = .secondaryLabelColor

            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: [
                "Rich Text Document (.rtf)",
                "Plain Text (.txt)",
            ])
            popup.selectItem(at: 0)

            let accessory = NSStackView(views: [formatLabel, popup])
            accessory.orientation = .horizontal
            accessory.alignment = .centerY
            accessory.spacing = 8
            panel.accessoryView = accessory

            panel.allowedContentTypes = [.rtf, .plainText]
            panel.nameFieldStringValue = URL(fileURLWithPath: self.filename)
                .deletingPathExtension()
                .appendingPathExtension("rtf")
                .lastPathComponent
        }

        if mode == .overwriteTmp {
            let tmpURL = URL(fileURLWithPath: "/tmp/playground-overwrite.txt")
            try? "existing file".write(to: tmpURL, atomically: true, encoding: .utf8)
            panel.directoryURL = tmpURL.deletingLastPathComponent()
            panel.nameFieldStringValue = tmpURL.lastPathComponent
        }

        self.actionLogger.log(.dialog, "Opening Save panel", details: "mode=\(String(describing: mode))")
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url {
                do {
                    if url.pathExtension.lowercased() == "rtf" {
                        let attributed = NSAttributedString(string: self.content)
                        let range = NSRange(location: 0, length: attributed.length)
                        let data = try attributed.data(
                            from: range,
                            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                        try data.write(to: url, options: .atomic)
                    } else {
                        try self.content.write(to: url, atomically: true, encoding: .utf8)
                    }
                    self.lastSavedPath = url.path
                    self.actionLogger.log(.dialog, "Saved file", details: url.path)
                } catch {
                    self.lastSavedPath = "error: \(error.localizedDescription)"
                    self.actionLogger.log(.dialog, "Save failed", details: error.localizedDescription)
                }
            } else {
                self.actionLogger.log(.dialog, "Save panel canceled")
            }
        }
    }

    private func showOpenPanel() {
        guard let window = self.owningWindow else {
            self.actionLogger.log(.dialog, "Open panel failed", details: "No owning window")
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .rtf, .data]

        self.actionLogger.log(.dialog, "Opening Open panel")
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url {
                self.lastOpenedPath = url.path
                self.actionLogger.log(.dialog, "Selected file", details: url.path)
            } else {
                self.actionLogger.log(.dialog, "Open panel canceled")
            }
        }
    }

    private func showAlert(withTextField: Bool) {
        guard let window = self.owningWindow else {
            self.actionLogger.log(.dialog, "Alert failed", details: "No owning window")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Peekaboo Playground Alert"
        alert.informativeText = withTextField
            ? "This alert includes a text field so `dialog input` can be exercised."
            : "Use `dialog click` to press buttons without needing TextEdit."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        var textField: NSTextField?
        if withTextField {
            let field = NSTextField(string: "")
            field.placeholderString = "Dialog Input Field"
            field.identifier = NSUserInterfaceItemIdentifier("dialog-input-field")
            field.setAccessibilityIdentifier("dialog-input-field")
            field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
            alert.accessoryView = field
            textField = field
        }

        self.actionLogger.log(.dialog, "Showing alert", details: "textField=\(withTextField)")
        alert.beginSheetModal(for: window) { response in
            let button = response == .alertFirstButtonReturn ? "OK" : "Cancel"
            let inputValue = textField?.stringValue
            if let inputValue, !inputValue.isEmpty {
                self.lastAlertResult = "\(button) (\(inputValue))"
            } else {
                self.lastAlertResult = button
            }

            self.actionLogger.log(.dialog, "Alert dismissed", details: self.lastAlertResult)
        }
    }
}

#if DEBUG && !SWIFT_PACKAGE
#Preview {
    ContentView()
        .environmentObject(ActionLogger.shared)
        .environmentObject(PlaygroundTabRouter())
        .frame(width: 1200, height: 800)
}
#endif
