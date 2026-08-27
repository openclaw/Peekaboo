import AppKit
import SwiftUI

enum PlaygroundSemanticWitnessIdentifier: String, CaseIterable, Sendable {
    case actionStepperValue = "action-stepper-value"
    case basicTextLastSubmitted = "basic-text-last-submitted"
    case secondaryClickCount = "secondary-click-count"
    case singleClickCount = "single-click-count"
    case verticalScrollOffset = "vertical-scroll-offset"

    var label: String {
        switch self {
        case .actionStepperValue: "Action Stepper Value"
        case .basicTextLastSubmitted: "Basic Text Last Submitted"
        case .secondaryClickCount: "Secondary Click Count"
        case .singleClickCount: "Single Click Count"
        case .verticalScrollOffset: "Vertical Scroll Offset"
        }
    }
}

enum PlaygroundSemanticWitnessLayout {
    /// Both the current and detached AX readers omit elements whose dimensions are 5 points or less.
    static let frameDimension: CGFloat = 8
}

struct TextInputSemanticState: Equatable, Sendable {
    private(set) var basicTextLastSubmitted = ""

    mutating func recordBasicTextSubmission(_ text: String) {
        self.basicTextLastSubmitted = text
    }
}

struct ClickTestingSemanticState: Equatable, Sendable {
    private(set) var singleClickCount = 0
    private(set) var secondaryClickCount = 0

    mutating func recordSingleClick() {
        self.singleClickCount += 1
    }

    mutating func recordSecondaryClick() {
        self.secondaryClickCount += 1
    }
}

struct ScrollTestingSemanticState: Equatable, Sendable {
    private(set) var verticalScrollOffset = "0"

    mutating func recordVerticalScrollOffset(_ offset: CGFloat) {
        let rounded = (offset * 100).rounded() / 100
        guard rounded != 0 else {
            self.verticalScrollOffset = "0"
            return
        }
        self.verticalScrollOffset = String(
            format: "%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            rounded)
    }
}

struct PlaygroundSemanticWitness: NSViewRepresentable {
    let identifier: PlaygroundSemanticWitnessIdentifier
    let value: String

    func makeNSView(context: Context) -> PlaygroundSemanticWitnessNSView {
        let view = PlaygroundSemanticWitnessNSView(frame: .zero)
        view.configure(identifier: self.identifier, value: self.value)
        return view
    }

    func updateNSView(_ nsView: PlaygroundSemanticWitnessNSView, context: Context) {
        nsView.configure(identifier: self.identifier, value: self.value)
    }
}

final class PlaygroundSemanticWitnessNSView: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.isBezeled = false
        self.isBordered = false
        self.isEditable = false
        self.isSelectable = false
        self.drawsBackground = false
        self.textColor = .clear
        self.focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func configure(identifier: PlaygroundSemanticWitnessIdentifier, value: String) {
        let valueChanged = self.accessibilityValue() != value
        self.stringValue = value
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.staticText)
        self.setAccessibilityIdentifier(identifier.rawValue)
        self.setAccessibilityLabel(identifier.label)
        self.setAccessibilityValue(value)

        if valueChanged, self.window != nil {
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }
}

extension View {
    func playgroundSemanticWitness(
        _ identifier: PlaygroundSemanticWitnessIdentifier,
        value: String) -> some View
    {
        self.overlay(alignment: .topLeading) {
            PlaygroundSemanticWitness(identifier: identifier, value: value)
                .frame(
                    width: PlaygroundSemanticWitnessLayout.frameDimension,
                    height: PlaygroundSemanticWitnessLayout.frameDimension)
        }
    }
}
