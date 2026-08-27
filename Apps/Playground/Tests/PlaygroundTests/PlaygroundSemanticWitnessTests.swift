import AppKit
import Testing
@testable import Playground

@MainActor
struct PlaygroundSemanticWitnessTests {
    @Test
    func `semantic witness identifiers are stable and unique`() {
        #expect(PlaygroundSemanticWitnessIdentifier.actionStepperValue.rawValue == "action-stepper-value")
        #expect(PlaygroundSemanticWitnessIdentifier.basicTextLastSubmitted.rawValue == "basic-text-last-submitted")
        #expect(PlaygroundSemanticWitnessIdentifier.secondaryClickCount.rawValue == "secondary-click-count")
        #expect(PlaygroundSemanticWitnessIdentifier.singleClickCount.rawValue == "single-click-count")
        #expect(PlaygroundSemanticWitnessIdentifier.verticalScrollOffset.rawValue == "vertical-scroll-offset")

        let identifiers = PlaygroundSemanticWitnessIdentifier.allCases.map(\.rawValue)
        #expect(Set(identifiers).count == identifiers.count)
    }

    @Test
    func `semantic state exposes deterministic initial and transition values`() {
        var textState = TextInputSemanticState()
        #expect(textState.basicTextLastSubmitted.isEmpty)
        textState.recordBasicTextSubmission("background text")
        #expect(textState.basicTextLastSubmitted == "background text")

        var clickState = ClickTestingSemanticState()
        #expect(clickState.singleClickCount == 0)
        #expect(clickState.secondaryClickCount == 0)
        clickState.recordSingleClick()
        clickState.recordSecondaryClick()
        clickState.recordSecondaryClick()
        #expect(clickState.singleClickCount == 1)
        #expect(clickState.secondaryClickCount == 2)

        var scrollState = ScrollTestingSemanticState()
        #expect(scrollState.verticalScrollOffset == "0")
        scrollState.recordVerticalScrollOffset(-123.456)
        #expect(scrollState.verticalScrollOffset == "-123.46")
        scrollState.recordVerticalScrollOffset(0.004)
        #expect(scrollState.verticalScrollOffset == "0")
    }

    @Test
    func `AX witness retains its identifier while exposing value transitions`() {
        let dimension = PlaygroundSemanticWitnessLayout.frameDimension
        #expect(dimension > 5)
        let view = PlaygroundSemanticWitnessNSView(
            frame: CGRect(x: 0, y: 0, width: dimension, height: dimension))
        view.configure(identifier: .singleClickCount, value: "0")

        #expect(view.frame.width > 5)
        #expect(view.frame.height > 5)
        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .staticText)
        #expect(view.accessibilityIdentifier() == "single-click-count")
        #expect(view.accessibilityLabel() == "Single Click Count")
        #expect(view.accessibilityValue() == "0")

        view.configure(identifier: .singleClickCount, value: "1")
        #expect(view.accessibilityIdentifier() == "single-click-count")
        #expect(view.accessibilityValue() == "1")
    }
}
