import SwiftUI

struct ClickTestingView: View {
    @EnvironmentObject var actionLogger: ActionLogger
    @State private var toggleState = false
    @State private var semanticState = ClickTestingSemanticState()
    @State private var lastClickType = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SectionHeader(title: "Click Testing", icon: "cursorarrow.click")

                // Basic buttons
                GroupBox("Basic Buttons") {
                    HStack(spacing: 20) {
                        Button("Single Click") {
                            self.semanticState.recordSingleClick()
                            self.lastClickType = "Single"
                            self.actionLogger.log(
                                .click,
                                "Single click on 'Single Click' button",
                                details: "Click count: \(self.semanticState.singleClickCount)")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("single-click-button")

                        Button("Secondary Button") {
                            self.semanticState.recordSecondaryClick()
                            self.actionLogger.log(.click, "Clicked 'Secondary Button'")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("secondary-button")

                        Button("Destructive") {
                            self.actionLogger.log(.click, "Clicked 'Destructive' button")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .accessibilityIdentifier("destructive-button")

                        Button("Disabled Button") {
                            // This should never be logged
                            self.actionLogger.log(.click, "ERROR: Disabled button was clicked!")
                        }
                        .disabled(true)
                        .accessibilityIdentifier("disabled-button")
                    }
                }

                // Toggle and switch
                GroupBox("Toggle Controls") {
                    HStack(spacing: 30) {
                        Toggle("Toggle Switch", isOn: self.$toggleState)
                            .onChange(of: self.toggleState) { _, newValue in
                                self.actionLogger.log(.click, "Toggle switched to: \(newValue)")
                            }
                            .accessibilityIdentifier("toggle-switch")

                        Button(self.toggleState ? "ON" : "OFF") {
                            self.toggleState.toggle()
                            self.actionLogger.log(
                                .click,
                                "Toggle button clicked - now: \(self.toggleState ? "ON" : "OFF")")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(self.toggleState ? .green : .gray)
                        .accessibilityIdentifier("toggle-button")
                    }
                }

                // Different sizes
                GroupBox("Button Sizes") {
                    VStack(spacing: 15) {
                        Button("Large Button") {
                            self.actionLogger.log(.click, "Clicked large button")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .accessibilityIdentifier("large-button")

                        Button("Regular Button") {
                            self.actionLogger.log(.click, "Clicked regular button")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .accessibilityIdentifier("regular-button")

                        Button("Small Button") {
                            self.actionLogger.log(.click, "Clicked small button")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityIdentifier("small-button")

                        Button("Mini Button") {
                            self.actionLogger.log(.click, "Clicked mini button")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .accessibilityIdentifier("mini-button")
                    }
                }

                // Click areas
                GroupBox("Click Areas") {
                    HStack(spacing: 20) {
                        ClickableArea(
                            title: "Double Click Me",
                            color: .blue,
                            identifier: "double-click-area")
                        {
                            self.actionLogger.log(.click, "Double-clicked area")
                        }
                        .onTapGesture(count: 2) {
                            self.actionLogger.log(.click, "Double-click detected on area")
                        }

                        ClickableArea(
                            title: "Right Click Me",
                            color: .purple,
                            identifier: "right-click-area")
                        {
                            self.actionLogger.log(.click, "Left-clicked right-click area")
                        }
                        .contextMenu {
                            Button("Context Action 1") {
                                self.actionLogger.log(.menu, "Context menu: Action 1")
                            }
                            Button("Context Action 2") {
                                self.actionLogger.log(.menu, "Context menu: Action 2")
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                self.actionLogger.log(.menu, "Context menu: Delete")
                            }
                        }

                        ClickableArea(
                            title: "Nested Click Target",
                            color: .orange,
                            identifier: "nested-click-area")
                        {
                            self.actionLogger.log(.click, "Clicked outer area")
                        }
                        .overlay(
                            Button("Inner Button") {
                                self.actionLogger.log(.click, "Clicked inner button (nested)")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("nested-inner-button"))
                    }
                }

                // Mouse move probe (used to verify `peekaboo move` end-to-end)
                GroupBox("Mouse Movement") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Move the cursor into this area to generate deterministic logs:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        MouseMoveProbeView()
                            .frame(height: 140)
                            .cornerRadius(12)
                    }
                    .padding(.vertical, 4)
                }

                // Status display
                if self.semanticState.singleClickCount > 0 {
                    GroupBox("Click Statistics") {
                        HStack {
                            Label("\(self.semanticState.singleClickCount) total clicks", systemImage: "hand.tap")
                            Spacer()
                            if !self.lastClickType.isEmpty {
                                Text("Last: \(self.lastClickType)")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .playgroundSemanticWitness(
            .singleClickCount,
            value: String(self.semanticState.singleClickCount))
        .playgroundSemanticWitness(
            .secondaryClickCount,
            value: String(self.semanticState.secondaryClickCount))
    }
}

struct ClickableArea: View {
    let title: String
    let color: Color
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            VStack {
                Image(systemName: "hand.tap.fill")
                    .font(.largeTitle)
                Text(self.title)
                    .font(.caption)
            }
            .frame(width: 120, height: 120)
            .background(self.color.opacity(0.2))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(self.color, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(self.identifier)
    }
}

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack {
            Image(systemName: self.icon)
                .font(.title2)
                .foregroundColor(.accentColor)
            Text(self.title)
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
        }
        .padding(.bottom, 10)
    }
}
