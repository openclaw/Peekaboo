import SwiftUI

struct TextInputView: View {
    @EnvironmentObject var actionLogger: ActionLogger
    @State private var basicText = ""
    @State private var multilineText = ""
    @State private var numberText = ""
    @State private var secureText = ""
    @State private var prefilledText = "This text is pre-filled"
    @State private var searchText = ""
    @State private var formattedText = ""
    @State private var semanticState = TextInputSemanticState()
    @FocusState private var focusedField: Field?

    enum Field: String {
        case basic, multiline, number, secure, prefilled, search, formatted
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SectionHeader(title: "Text Input Testing", icon: "textformat")

                // Basic text fields
                GroupBox("Text Fields") {
                    VStack(alignment: .leading, spacing: 15) {
                        LabeledTextField(
                            label: "Basic Text Field",
                            text: self.$basicText,
                            placeholder: "Type here...",
                            identifier: "basic-text-field")
                            .focused(self.$focusedField, equals: .basic)
                            .onSubmit {
                                self.semanticState.recordBasicTextSubmission(self.basicText)
                                self.actionLogger.log(
                                    .text,
                                    "Submitted basic text field",
                                    details: "Value: '\(self.basicText)'")
                            }
                            .onChange(of: self.basicText) { oldValue, newValue in
                                if !oldValue.isEmpty || !newValue.isEmpty {
                                    self.actionLogger.log(
                                        .text,
                                        "Basic text changed",
                                        details: "From: '\(oldValue)' To: '\(newValue)'")
                                }
                            }

                        LabeledTextField(
                            label: "Number Field",
                            text: self.$numberText,
                            placeholder: "Numbers only...",
                            identifier: "number-text-field")
                            .focused(self.$focusedField, equals: .number)
                            .onChange(of: self.numberText) { oldValue, newValue in
                                // Filter non-numeric characters
                                let filtered = newValue.filter(\.isNumber)
                                if filtered != newValue {
                                    self.numberText = filtered
                                    self.actionLogger.log(
                                        .text,
                                        "Non-numeric input filtered",
                                        details: "Attempted: '\(newValue)'")
                                } else if !oldValue.isEmpty || !newValue.isEmpty {
                                    self.actionLogger.log(
                                        .text,
                                        "Number text changed",
                                        details: "Value: '\(newValue)'")
                                }
                            }

                        HStack {
                            Text("Secure Field:")
                                .frame(width: 120, alignment: .trailing)
                            SecureField("Password", text: self.$secureText)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("secure-text-field")
                                .focused(self.$focusedField, equals: .secure)
                                .onSubmit {
                                    self.actionLogger.log(
                                        .text,
                                        "Submitted secure field",
                                        details: "Length: \(self.secureText.count) characters")
                                }
                        }

                        LabeledTextField(
                            label: "Pre-filled Field",
                            text: self.$prefilledText,
                            placeholder: "",
                            identifier: "prefilled-text-field")
                            .focused(self.$focusedField, equals: .prefilled)
                            .onChange(of: self.prefilledText) { oldValue, newValue in
                                self.actionLogger.log(
                                    .text,
                                    "Pre-filled text modified",
                                    details: "From: '\(oldValue)' To: '\(newValue)'")
                            }
                    }
                }

                // Hidden fixtures

                HiddenFieldsView()
                    .environmentObject(self.actionLogger)

                PermissionBubbleView()
                    .environmentObject(self.actionLogger)

                // Search field
                GroupBox("Search Field") {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search...", text: self.$searchText)
                            .textFieldStyle(.plain)
                            .accessibilityIdentifier("search-field")
                            .focused(self.$focusedField, equals: .search)
                            .onSubmit {
                                self.actionLogger.log(
                                    .text,
                                    "Search submitted",
                                    details: "Query: '\(self.searchText)'")
                            }

                        if !self.searchText.isEmpty {
                            Button(action: {
                                self.searchText = ""
                                self.actionLogger.log(.text, "Search cleared")
                            }, label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            })
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("clear-search-button")
                        }
                    }
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                }

                // Multiline text
                GroupBox("Multiline Text") {
                    VStack(alignment: .leading) {
                        Text("Text Editor:")
                        TextEditor(text: self.$multilineText)
                            .frame(height: 100)
                            .border(Color.gray.opacity(0.3))
                            .accessibilityIdentifier("multiline-text-editor")
                            .focused(self.$focusedField, equals: .multiline)
                            .onChange(of: self.multilineText) { oldValue, newValue in
                                let oldLines = oldValue.components(separatedBy: .newlines).count
                                let newLines = newValue.components(separatedBy: .newlines).count
                                if oldLines != newLines {
                                    self.actionLogger.log(
                                        .text,
                                        "Multiline text changed",
                                        details: "Lines: \(oldLines) → \(newLines), Characters: \(newValue.count)")
                                }
                            }

                        HStack {
                            Text("\(self.multilineText.count) characters")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Clear") {
                                self.multilineText = ""
                                self.actionLogger.log(.text, "Multiline text cleared")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityIdentifier("clear-multiline-button")
                        }
                    }
                }

                // Special characters
                GroupBox("Special Characters") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Test special character input:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        TextField("Type special characters...", text: self.$formattedText)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("special-char-field")
                            .focused(self.$focusedField, equals: .formatted)
                            .onChange(of: self.formattedText) { _, newValue in
                                if newValue.contains(where: { !$0.isASCII }) {
                                    self.actionLogger.log(
                                        .text,
                                        "Special characters entered",
                                        details: "Text: '\(newValue)'")
                                }
                            }

                        HStack(spacing: 10) {
                            ForEach(["@", "#", "$", "€", "™", "©", "®", "😀"], id: \.self) { char in
                                Button(char) {
                                    self.formattedText.append(char)
                                    self.actionLogger.log(
                                        .text,
                                        "Special character button pressed",
                                        details: "Character: '\(char)'")
                                }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("special-char-\(char)")
                            }
                        }
                    }
                }

                // Focus control
                GroupBox("Focus Control") {
                    HStack(spacing: 20) {
                        Button("Focus Basic Field") {
                            self.focusedField = .basic
                            self.actionLogger.log(.focus, "Programmatically focused basic field")
                        }
                        .accessibilityIdentifier("focus-basic-button")

                        Button("Focus Search") {
                            self.focusedField = .search
                            self.actionLogger.log(.focus, "Programmatically focused search field")
                        }
                        .accessibilityIdentifier("focus-search-button")

                        Button("Clear Focus") {
                            self.focusedField = nil
                            self.actionLogger.log(.focus, "Cleared field focus")
                        }
                        .accessibilityIdentifier("clear-focus-button")

                        Spacer()

                        if let focused = focusedField {
                            Label("Focused: \(focused.rawValue)", systemImage: "scope")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding()
        }
        .playgroundSemanticWitness(
            .basicTextLastSubmitted,
            value: self.semanticState.basicTextLastSubmitted)
        .onAppear {
            self.actionLogger.log(.focus, "Text input view appeared")
        }
    }
}

struct LabeledTextField: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    let identifier: String

    var body: some View {
        HStack {
            Text("\(self.label):")
                .frame(width: 120, alignment: .trailing)
            TextField(self.placeholder, text: self.$text)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(self.identifier)
        }
    }
}
