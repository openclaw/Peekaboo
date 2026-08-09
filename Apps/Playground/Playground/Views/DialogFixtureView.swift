import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DialogFixtureView: View {
    @EnvironmentObject private var actionLogger: ActionLogger

    @State private var owningWindow: NSWindow?
    @State private var filename: String = "playground-dialog-fixture.rtf"
    @State private var content: String = "Peekaboo Playground Dialog Fixture"

    @State private var lastSavedPath: String = "(none)"
    @State private var lastOpenedPath: String = "(none)"
    @State private var lastAlertResult: String = "(none)"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Dialog Fixture")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Save/Open Panels")
                    .font(.headline)

                HStack {
                    Button("Show Save Panel (TextEdit-like)") {
                        self.showSavePanel(mode: .textEditLike)
                    }
                    .accessibilityIdentifier("dialog-fixture-show-save-texteditlike")

                    Button("Show Save Panel (Overwrite /tmp)") {
                        self.showSavePanel(mode: .overwriteTmp)
                    }
                    .accessibilityIdentifier("dialog-fixture-show-save-overwrite")

                    Button("Show Open Panel") {
                        self.showOpenPanel()
                    }
                    .accessibilityIdentifier("dialog-fixture-show-open")

                    Spacer()
                }

                HStack {
                    Text("Filename:")
                        .foregroundColor(.secondary)
                    TextField("", text: self.$filename)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 420)
                        .accessibilityIdentifier("dialog-fixture-filename")
                    Spacer()
                }

                HStack {
                    Text("Content:")
                        .foregroundColor(.secondary)
                    TextField("", text: self.$content)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 560)
                        .accessibilityIdentifier("dialog-fixture-content")
                    Spacer()
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Last saved:")
                            .foregroundColor(.secondary)
                        Text(self.lastSavedPath)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("dialog-fixture-last-saved")
                        Spacer()
                    }

                    HStack {
                        Text("Last opened:")
                            .foregroundColor(.secondary)
                        Text(self.lastOpenedPath)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("dialog-fixture-last-opened")
                        Spacer()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Alerts")
                    .font(.headline)

                HStack {
                    Button("Show Alert") {
                        self.showAlert(withTextField: false)
                    }
                    .accessibilityIdentifier("dialog-fixture-show-alert")

                    Button("Show Alert (with text field)") {
                        self.showAlert(withTextField: true)
                    }
                    .accessibilityIdentifier("dialog-fixture-show-alert-textfield")

                    Spacer()
                }

                HStack {
                    Text("Last alert:")
                        .foregroundColor(.secondary)
                    Text(self.lastAlertResult)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("dialog-fixture-last-alert-result")
                        .id(self.lastAlertResult)
                    Spacer()
                }
            }

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            let tmpURL = URL(fileURLWithPath: "/tmp/playground-dialog-overwrite.txt")
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
            field.identifier = NSUserInterfaceItemIdentifier("dialog-fixture-input-field")
            field.setAccessibilityIdentifier("dialog-fixture-input-field")
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
    DialogFixtureView()
        .environmentObject(ActionLogger.shared)
}
#endif
