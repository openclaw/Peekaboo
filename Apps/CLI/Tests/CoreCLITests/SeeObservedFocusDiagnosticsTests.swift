import CoreGraphics
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@MainActor
@Suite(.tags(.safe))
struct SeeObservedFocusDiagnosticsTests {
    @Test
    func `focused ancestors remain ambiguous without logging element contents`() {
        let elements = [
            Self.element(type: .group, focused: true),
            Self.element(type: .group, focused: true),
            Self.element(type: .textField, focused: true),
            Self.element(type: .button, focused: false),
            Self.element(type: .other, focused: nil),
        ]
        let summary = SeeCommand.observedFocusSummary(elements: elements, metadata: Self.metadata())

        #expect(summary == "rawTrue=3 rawFalse=1 rawUnknown=1 rawFocusedTypes=[group:2,textField:1] " +
            "rawResolver=multipleFocusedElements cached=false partial=false truncated=false attached=false")
        #expect(!summary.contains("PRIVATE"))
        #expect(FocusedElementReceiptResolver.attachingObservedFocus(
            to: Self.context, elements: elements
        )?.focusedElement == nil)
    }

    @Test
    func `raw menu focus counts do not change the shared resolver exclusion`() {
        let menu = Self.element(type: .textField, focused: true, menu: true)
        let summary = SeeCommand.observedFocusSummary(
            elements: [Self.element(type: .textField, focused: true), menu],
            metadata: Self.metadata()
        )

        #expect(summary.contains("rawTrue=2 rawFalse=0 rawUnknown=0 rawFocusedTypes=[textField:2]"))
        #expect(summary.contains("rawResolver=unique"))
        #expect(summary.hasSuffix("attached=false"))
    }

    @Test(arguments: [false, true])
    func `missing context is distinguished from absent focus`(hasContext: Bool) {
        let summary = SeeCommand.observedFocusSummary(
            elements: [], metadata: Self.metadata(context: hasContext ? Self.context : nil)
        )

        #expect(summary.contains("rawTrue=0 rawFalse=0 rawUnknown=0 rawFocusedTypes=[]"))
        #expect(summary.contains("rawResolver=\(hasContext ? "noFocusedElement" : "noWindowContext")"))
    }

    @Test
    func `observation qualifiers remain separate from the raw resolver result`() {
        let element = Self.element(type: .textField, focused: true)
        let metadata = Self.metadata(
            context: FocusedElementReceiptResolver.attachingObservedFocus(to: Self.context, elements: [element]),
            cached: true,
            partial: true,
            truncated: true
        )
        let summary = SeeCommand.observedFocusSummary(elements: [element], metadata: metadata)

        #expect(summary.contains("rawResolver=unique cached=true partial=true truncated=true attached=true"))
        #expect(metadata.windowContext?.focusedElement != nil)
        #expect(!summary.contains("PRIVATE"))
    }

    @Test
    func `ROI subset never reinterprets an ambiguous full observation as unique focus`() throws {
        let inside = Self.element(type: .textField, focused: true)
        let outside = Self.element(
            type: .textField, focused: true, frame: CGRect(x: 200, y: 10, width: 100, height: 20)
        )
        let original = FocusedElementReceiptResolver.attachingObservedFocus(
            to: Self.context, elements: [inside, outside]
        )
        let viewport = try CaptureViewport(
            sourceLogicalBounds: #require(Self.context.windowBounds),
            requestedWindowRelativeBounds: CGRect(x: 0, y: 0, width: 120, height: 60),
            deliveredWindowRelativeBounds: CGRect(x: 0, y: 0, width: 120, height: 60),
            logicalBounds: CGRect(x: 0, y: 0, width: 120, height: 60),
            sourceImageSize: CGSize(width: 400, height: 300)
        )
        let coordinates = CaptureCoordinateContext(
            metadata: CaptureMetadata(size: viewport.logicalBounds.size, mode: .window, viewport: viewport),
            referenceID: "synthetic-roi"
        )
        let summary = SeeCommand.observedFocusSummary(
            elements: [inside], metadata: Self.metadata(context: original, coordinateContext: coordinates)
        )

        #expect(original?.focusedElement == nil)
        #expect(summary == "scope=roi_filtered rawResolver=not_evaluated")
    }

    private static let context = WindowContext(
        applicationName: "PRIVATE_APPLICATION",
        applicationProcessId: 42,
        windowTitle: "PRIVATE_WINDOW",
        windowID: 77,
        windowBounds: CGRect(x: 0, y: 0, width: 400, height: 300)
    )

    private static func metadata(
        context: WindowContext? = Self.context,
        cached: Bool = false,
        partial: Bool = false,
        truncated: Bool = false,
        coordinateContext: CaptureCoordinateContext? = nil
    ) -> DetectionMetadata {
        DetectionMetadata(
            detectionTime: 0,
            elementCount: 0,
            method: cached ? "AXorcist (cached)" : "AXorcist",
            warnings: partial ? [DetectionMetadata.applicationScopedAccessibilityFallbackWarning] : [],
            windowContext: context,
            truncationInfo: truncated ? DetectionTruncationInfo(maxDepthReached: true) : nil,
            captureCoordinateContext: coordinateContext
        )
    }

    private static func element(
        type: ElementType,
        focused: Bool?,
        menu: Bool = false,
        frame: CGRect = CGRect(x: 10, y: 10, width: 100, height: 20)
    ) -> DetectedElement {
        var attributes = ["title": "PRIVATE_TITLE", "identifier": "PRIVATE_IDENTIFIER", "role": "PRIVATE_ROLE"]
        if let focused {
            attributes["isFocused"] = String(focused)
        }
        if menu {
            attributes["source"] = "applicationMenuBar"
        }
        return DetectedElement(
            id: "PRIVATE_ID",
            type: type,
            label: "PRIVATE_LABEL",
            value: "PRIVATE_VALUE",
            bounds: frame,
            attributes: attributes
        )
    }
}
