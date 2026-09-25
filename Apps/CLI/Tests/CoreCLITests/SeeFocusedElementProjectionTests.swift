import CoreGraphics
import Foundation
import Testing
@_spi(Testing) import PeekabooAutomationKit
@testable import PeekabooCLI

@MainActor
@Suite(.tags(.safe))
struct SeeFocusedElementProjectionTests {
    enum FocusScenario: CaseIterable, Sendable {
        case known
        case absent
        case ambiguous
        case cached
        case applicationPartial
    }

    @Test(arguments: FocusScenario.allCases)
    func `see JSON projects only established focus without a runtime`(scenario: FocusScenario) throws {
        let detection = Self.detection(scenario: scenario)
        let context = Self.context(detection: detection)
        var command = SeeCommand()
        command.mode = .window

        let result = command.makeJSONResult(
            context: context,
            snapshotPaths: SnapshotPaths(
                raw: "", annotated: "", map: context.snapshotReusable ? "synthetic/snapshot.json" : ""
            )
        )
        let encoded = try JSONEncoder().encode(result)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let decoded = try JSONDecoder().decode(SeeResult.self, from: encoded)

        #expect(command.runtime == nil)
        #expect(object["focused_element_id"] == nil)
        if scenario == .known {
            let expected = try #require(detection.metadata.windowContext?.focusedElement)
            #expect(decoded.focused_element == expected)
            let projected = try #require(object["focused_element"] as? [String: Any])
            let identityJSON = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as? [String: Any]
            )
            #expect(NSDictionary(dictionary: projected).isEqual(to: identityJSON))
            #expect(projected["value"] == nil)
        } else {
            #expect(decoded.focused_element == nil)
            #expect(object["focused_element"] == nil)
            if scenario != .absent {
                #expect(detection.elements.all.contains { $0.isFocused == true })
            }
        }
        if scenario == .applicationPartial {
            #expect(detection.metadata.windowContext?.focusedElement != nil)
            #expect(result.snapshot_id == nil)
            #expect(!result.snapshot_reusable)
            #expect(!result.mutation_targeting_available)
            #expect(result.interactable_count == 0)
            #expect(result.ui_elements.allSatisfy { !$0.is_actionable && $0.is_value_settable == nil })
        }
    }

    @Test
    func `ROI focus keeps the existing global frame while element bounds stay local`() throws {
        let detection = Self.detection(scenario: .known)
        let expectedFocus = try #require(detection.metadata.windowContext?.focusedElement)
        let viewport = CaptureViewport(
            sourceLogicalBounds: Self.windowBounds,
            requestedWindowRelativeBounds: CGRect(x: 30, y: 50, width: 250, height: 100),
            deliveredWindowRelativeBounds: CGRect(x: 30, y: 50, width: 250, height: 100),
            logicalBounds: CGRect(x: 130, y: 250, width: 250, height: 100),
            sourceImageSize: Self.windowBounds.size
        )
        let coordinateContext = CaptureCoordinateContext(
            metadata: CaptureMetadata(size: viewport.logicalBounds.size, mode: .window, viewport: viewport),
            referenceID: detection.snapshotId
        )
        let localFrame = CGRect(x: 10, y: 10, width: 180, height: 24)
        let context = Self.context(
            detection: detection,
            elements: DetectedElements(textFields: [Self.element(frame: localFrame)]),
            coordinateContext: coordinateContext
        )
        var command = SeeCommand()
        command.mode = .window

        let projected = command.makeJSONResult(
            context: context,
            snapshotPaths: SnapshotPaths(raw: "", annotated: "", map: "synthetic/snapshot.json")
        )
        let decoded = try JSONDecoder().decode(SeeResult.self, from: JSONEncoder().encode(projected))

        #expect(command.runtime == nil)
        #expect(decoded.focused_element == expectedFocus)
        #expect(decoded.focused_element?.frame == Self.elementFrame)
        #expect(decoded.ui_elements.first?.bounds.x == Double(localFrame.minX))
        #expect(decoded.ui_elements.first?.bounds.y == Double(localFrame.minY))
        #expect(decoded.coordinate_context?.viewport == viewport)
    }

    private static let windowBounds = CGRect(x: 100, y: 200, width: 600, height: 400)
    private static let elementFrame = CGRect(x: 140, y: 260, width: 180, height: 24)

    private static func element(
        id: String = "field",
        focused: Bool = true,
        frame: CGRect = Self.elementFrame
    ) -> DetectedElement {
        DetectedElement(
            id: id,
            type: .textField,
            label: "Editor",
            value: "synthetic text",
            bounds: frame,
            attributes: [
                "role": "AXTextField",
                "title": "Editor",
                "identifier": id,
                "isFocused": String(focused),
                "isActionable": "true",
                "isValueSettable": "true",
            ]
        )
    }

    private static func detection(scenario: FocusScenario) -> ElementDetectionResult {
        let windowIdentity = WindowMutationIdentity(
            windowID: 77,
            ownerProcessIdentifier: 4242,
            ownerProcessStartIdentity: 101,
            capturedBounds: self.windowBounds
        )
        let windowContext = WindowContext(
            applicationName: "Synthetic Editor",
            applicationProcessId: 4242,
            applicationProcessStartIdentity: 101,
            windowTitle: "Document",
            windowID: 77,
            windowBounds: self.windowBounds,
            windowMutationIdentity: windowIdentity
        )
        var elements = [self.element(focused: scenario != .absent)]
        if scenario == .ambiguous {
            elements.append(self.element(id: "other-field"))
        }
        let result = ElementDetectionResultBuilder.makeResult(
            snapshotId: "ps1_0123456789abcdef0123456789abcdef",
            elements: elements,
            usedCache: scenario == .cached,
            windowContext: windowContext,
            isDialog: false
        )
        guard scenario == .applicationPartial else { return result }
        return ElementDetectionResult(
            snapshotId: result.snapshotId,
            screenshotPath: "",
            elements: result.elements,
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: result.elements.all.count,
                method: "AXorcist",
                warnings: [DetectionMetadata.applicationScopedAccessibilityFallbackWarning],
                windowContext: result.metadata.windowContext,
                truncationInfo: DetectionTruncationInfo(incompleteAccessibilityRead: true),
                applicationScopedAccessibilityFallbackOrigin:
                ApplicationScopedAccessibilityFallbackOrigin(windowIdentity: windowIdentity)
            )
        )
    }

    private static func context(
        detection: ElementDetectionResult,
        elements: DetectedElements? = nil,
        coordinateContext: CaptureCoordinateContext? = nil
    ) -> SeeCommandRenderContext {
        SeeCommandRenderContext(
            snapshotId: detection.snapshotId,
            screenshotPath: "",
            screenshotData: nil,
            annotatedPath: nil,
            annotatedData: nil,
            metadata: detection.metadata,
            elements: elements ?? detection.elements,
            coordinateContext: coordinateContext,
            analysis: nil,
            executionTime: 0,
            observation: nil,
            menuBar: nil,
            receipt: .none
        )
    }
}
