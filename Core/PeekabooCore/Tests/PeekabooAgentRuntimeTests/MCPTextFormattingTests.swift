import CoreGraphics
import PeekabooAutomation
import Testing
@testable import PeekabooAgentRuntime

struct MCPTextFormattingTests {
    @Test
    func `See element formatter surfaces extra metadata`() {
        let element = UIElement(
            id: "B1",
            elementId: "B1",
            role: "button",
            title: "Continue",
            label: "Continue",
            value: "Primary",
            description: "Primary action",
            help: "Press to continue",
            identifier: "continue.button",
            frame: CGRect(x: 540, y: 320, width: 80, height: 32),
            isActionable: false,
            isValueSettable: true,
            keyboardShortcut: "⏎")

        let line = SeeElementTextFormatter.describe(element)
        let expected = [
            #"  B1"#,
            #""Continue""#,
            "at (540, 320) size 80×32",
            #"value: "Primary""#,
            #"desc: "Primary action""#,
            #"help: "Press to continue""#,
            "shortcut: ⏎",
            "identifier: continue.button",
            "[value settable]",
            "[not actionable]",
        ].joined(separator: " - ")

        #expect(line == expected)
    }

    @Test
    func `Detected element conversion preserves accessibility metadata`() throws {
        let detected = DetectedElement(
            id: "S1",
            type: .slider,
            label: "Liquid Glass Tint Amount",
            value: "0.5",
            bounds: CGRect(x: 10, y: 20, width: 200, height: 16),
            isEnabled: true,
            attributes: [
                "role": "AXSlider",
                "description": "Liquid Glass Tint Amount",
                "roleDescription": "slider",
                "isActionable": "true",
                "isValueSettable": "true",
                "axEnabledKnown": "true",
            ])

        let converted = try #require(DetectedElementSnapshotConverter.convert([detected]).first)
        #expect(converted.role == "AXSlider")
        #expect(converted.title == nil)
        #expect(converted.label == "Liquid Glass Tint Amount")
        #expect(converted.value == "0.5")
        #expect(converted.description == "Liquid Glass Tint Amount")
        #expect(converted.roleDescription == "slider")
        #expect(converted.isActionable)
        #expect(converted.isEnabled == true)
        #expect(converted.isValueSettable == true)
    }

    @Test
    func `See element formatter does not duplicate value-only labels`() {
        let element = UIElement(
            id: "T1",
            elementId: "T1",
            role: "textfield",
            value: "search query",
            frame: CGRect(x: 20, y: 40, width: 180, height: 24),
            isActionable: true)

        let line = SeeElementTextFormatter.describe(element)

        #expect(line == #"  T1 - "value: search query" - at (20, 40) size 180×24"#)
    }

    @Test
    func `snapshot query selection never falls back to OCR semantic evidence`() throws {
        let ocr = UIElement(
            id: "ocr_1",
            elementId: "ocr_1",
            role: "AXStaticText",
            label: "August",
            description: "ocr",
            confidence: 0.93,
            frame: CGRect(x: 20, y: 40, width: 100, height: 20),
            isActionable: false)
        let ordinary = UIElement(
            id: "S1",
            elementId: "S1",
            role: "AXStaticText",
            label: "August",
            frame: CGRect(x: 20, y: 70, width: 100, height: 20),
            isActionable: false)

        let selected = try #require(SnapshotElementQuerySelector.preferred(in: [ocr, ordinary]))

        #expect(selected.id == "S1")
        #expect(SnapshotElementQuerySelector.preferred(in: [ocr]) == nil)
    }
}
