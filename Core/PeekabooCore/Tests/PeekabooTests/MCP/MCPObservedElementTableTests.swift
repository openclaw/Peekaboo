import CoreGraphics
import Foundation
import MCP
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooCore
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@Suite(.serialized)
struct MCPObservedElementTableTests {
    private static let uiSnapshots = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner())

    private static let button = DetectedElement(
        id: "elem_1",
        type: .button,
        label: "Submit\nand close",
        bounds: CGRect(x: 150, y: 250, width: 40, height: 20),
        attributes: ["role": "AXButton", "description": "Submit the form"])
    private static let field = DetectedElement(
        id: "elem_2",
        type: .textField,
        label: "Username",
        value: "alice",
        bounds: CGRect(x: 400, y: 500, width: 200, height: 24),
        attributes: [
            "role": "AXTextField",
            "isValueSettable": "true",
            "isFocused": "true",
            "selectedTextRangeLocation": "1",
            "selectedTextRangeLength": "2",
        ])

    @Test(arguments: ["see", "inspect_ui"])
    @MainActor
    func `Observation tools advertise include_elements as an off-by-default boolean`(_ toolName: String) throws {
        let context = Self.makeContext(detection: Self.detection())
        let schema: Value = toolName == "see"
            ? SeeTool(context: context).inputSchema
            : InspectUITool(context: context).inputSchema
        let property = try #require(schema.objectValue?["properties"]?.objectValue?["include_elements"]?.objectValue)

        #expect(property["type"] == .string("boolean"))
        #expect(property["default"] == .bool(false))
        #expect(property["description"]?.stringValue?.hasPrefix("Optional.") == true)
        #expect(property["description"]?.stringValue?.contains("_meta.ui_elements") == true)
    }

    @Test(arguments: [nil, false] as [Bool?])
    func `Inspect UI omits the element table unless requested`(_ flag: Bool?) async throws {
        await Self.uiSnapshots.removeAllSnapshots()
        let context = await Self.makeContext(detection: Self.detection())
        let arguments: [String: Any] = flag.map { ["include_elements": $0] } ?? [:]
        let response = try await InspectUITool(context: context).execute(arguments: ToolArguments(raw: arguments))

        #expect(!response.isError)
        #expect(response.meta?.objectValue?["ui_elements"] == nil)
        let wire = try Self.wireMetadata(response, toolName: "inspect_ui")
        #expect(wire["ui_elements"] == nil)
        #expect(wire["snapshot_id"] == nil)
        #expect(response.content.contains {
            if case let .text(text, _, _) = $0 {
                text.contains("Text selection elem_2: UTF-16 location 1, length 2")
            } else {
                false
            }
        })
    }

    @Test
    func `Inspect UI returns the CLI element shape when requested`() async throws {
        await Self.uiSnapshots.removeAllSnapshots()
        let context = await Self.makeContext(detection: Self.detection())
        let response = try await InspectUITool(context: context)
            .execute(arguments: ToolArguments(raw: ["include_elements": true]))

        #expect(!response.isError)
        let meta = try #require(response.meta?.objectValue)
        let snapshotID = try #require(meta["snapshot_id"]?.stringValue)
        let wire = try Self.wireMetadata(response, toolName: "inspect_ui")
        #expect(wire["snapshot_id"] == .string(snapshotID))

        let rows = try Self.rows(in: wire["ui_elements"])
        #expect(rows == [
            UIElementSummary(Self.button, mutationTargetingAvailable: true),
            UIElementSummary(Self.field, mutationTargetingAvailable: true),
        ])
        #expect(rows.first?.label == "Submit\nand close")
        #expect(rows.first?.role == "button")
        #expect(rows.first?.ax_role == "AXButton")
        #expect(rows.first?.description == "Submit the form")
        #expect(rows.last?.value == "alice")
        #expect(rows.last?.selected_text_range == TextSelectionRange(location: 1, length: 2))
        #expect(rows.last?.bounds == UIElementBounds(CGRect(x: 400, y: 500, width: 200, height: 24)))

        let first = try #require(wire["ui_elements"]?.arrayValue?.first?.objectValue)
        #expect(Set(first.keys) == [
            "id", "role", "ax_role", "label", "description", "bounds", "is_actionable", "is_enabled",
        ])
        let bounds = try #require(first["bounds"]?.objectValue)
        #expect(Set(bounds.keys) == ["x", "y", "width", "height"])
    }

    @Test
    @MainActor
    func `normal see text exposes selection without changing the signed snapshot element shape`() async {
        let elements = [Self.button, Self.field]
        let summary = await SeeSummaryBuilder(
            snapshot: UISnapshot(),
            elements: DetectedElementSnapshotConverter.convert(elements),
            screenshotPath: "/synthetic/fixture.png",
            truncationInfo: nil,
            traversalBudget: nil,
            selectionSummaries: ObservedTextSelectionSummary.lines(for: elements)).build()
        #expect(summary.contains("Text selection elem_2: UTF-16 location 1, length 2"))
        #expect(!summary.contains("Text selection elem_1"))
        #expect(UIElementSummary(Self.field, mutationTargetingAvailable: false).selected_text_range == nil)
    }

    @Test
    @MainActor
    func `See metadata carries the element table only when requested`() throws {
        let context = Self.makeContext(detection: Self.detection())
        let observation = Self.observation(viewport: nil)
        let tool = SeeTool(context: context)
        let snapshot = UISnapshot()

        let plain = try tool.makeMetadata(
            snapshot: snapshot,
            elements: DetectedElementSnapshotConverter.convert(observation.elements?.elements.all ?? []),
            observation: observation,
            actionResult: UIAutomationActionResult(payload: observation, outcome: nil))
        #expect(plain.objectValue?["ui_elements"] == nil)
        let snapshotID = try #require(plain.objectValue?["snapshot_id"]?.stringValue)
        #expect(try Self.wireMetadata(.text("see", meta: plain), toolName: "see")["snapshot_id"] == nil)

        let table = try tool.makeMetadata(
            snapshot: snapshot,
            elements: DetectedElementSnapshotConverter.convert(observation.elements?.elements.all ?? []),
            observation: observation,
            actionResult: UIAutomationActionResult(payload: observation, outcome: nil),
            includeElements: true)
        let wire = try Self.wireMetadata(.text("see", meta: table), toolName: "see")
        #expect(wire["snapshot_id"] == .string(snapshotID))
        #expect(try Self.rows(in: wire["ui_elements"]) == [
            UIElementSummary(Self.button, mutationTargetingAvailable: true),
            UIElementSummary(Self.field, mutationTargetingAvailable: true),
        ])
    }

    @Test
    @MainActor
    func `See element table uses ROI-local presentation bounds`() throws {
        let source = CGRect(x: 100, y: 200, width: 640, height: 480)
        let local = CGRect(x: 0, y: 0, width: 100, height: 100)
        let viewport = CaptureViewport(
            sourceLogicalBounds: source,
            requestedWindowRelativeBounds: local,
            deliveredWindowRelativeBounds: local,
            logicalBounds: local.offsetBy(dx: source.minX, dy: source.minY),
            sourceImageSize: source.size)
        let observation = Self.observation(viewport: viewport)
        let metadata = try SeeTool(context: Self.makeContext(detection: Self.detection())).makeMetadata(
            snapshot: UISnapshot(),
            elements: [],
            observation: observation,
            actionResult: UIAutomationActionResult(payload: observation, outcome: nil),
            includeElements: true)

        let rows = try Self.rows(in: metadata.objectValue?["ui_elements"])
        #expect(rows.map(\.id) == ["elem_1"])
        #expect(rows.first?.bounds == UIElementBounds(CGRect(x: 50, y: 50, width: 40, height: 20)))
    }

    @Test(arguments: [false, true])
    func `Element table derives mutation claims from observation metadata`(_ applicationPartial: Bool) throws {
        let metadata = DetectionMetadata(
            detectionTime: 0.01,
            elementCount: 1,
            method: "AXorcist",
            warnings: applicationPartial ? [DetectionMetadata.applicationScopedAccessibilityFallbackWarning] : [])
        let table = try ObservedElementTableMetadata.value(for: [Self.field], metadata: metadata)
        let rows = try Self.rows(in: table)
        let row = try #require(rows.first)

        #expect(row.is_actionable == (!applicationPartial && Self.field.isActionable))
        #expect(row.is_value_settable == (applicationPartial ? nil : true))
        #expect(row.value == Self.field.value)
    }

    @Test(arguments: [nil, "", "see", "inspect_ui", "image", "capture", "click", "type"] as [String?])
    func `Element table is allowlisted only for see and inspect_ui`(_ toolName: String?) throws {
        let table = try ObservedElementTableMetadata.value(
            for: [Self.button],
            metadata: Self.detection().metadata)
        let response = ToolResponse.text("observation", meta: .object([
            "ui_elements": table,
            "snapshot_id": .string("ps1_synthetic"),
            "internal_diagnostics": .string("must remain internal"),
        ]))
        let wire = try Self.wireMetadata(response, toolName: toolName)
        let allowed = toolName == "see" || toolName == "inspect_ui"

        #expect((wire["ui_elements"] != nil) == allowed)
        #expect(wire["snapshot_id"] == (allowed ? .string("ps1_synthetic") : nil))
        #expect(wire["internal_diagnostics"] == nil)
        #expect(MCPToolResponseMetadataProjector.agentFields(from: response.meta)["ui_elements"] == nil)
    }

    // MARK: - Helpers

    private static func detection() -> ElementDetectionResult {
        ElementDetectionResult(
            snapshotId: "synthetic-element-table",
            screenshotPath: "",
            elements: DetectedElements(buttons: [self.button], textFields: [self.field]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 2,
                method: "AXorcist",
                windowContext: WindowContext(applicationName: "TestApp", windowTitle: "Main")))
    }

    private static func observation(viewport: CaptureViewport?) -> DesktopObservationResult {
        let capture = CaptureMetadata(
            size: viewport?.logicalBounds.size ?? CGSize(width: 640, height: 480),
            mode: .window,
            viewport: viewport)
        return DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .appWindow),
            capture: CaptureResult(imageData: Data(), metadata: capture),
            elements: self.detection())
    }

    private static func rows(in value: Value?) throws -> [UIElementSummary] {
        let value = try #require(value)
        return try JSONDecoder().decode([UIElementSummary].self, from: JSONEncoder().encode(value))
    }

    private static func wireMetadata(_ response: ToolResponse, toolName: String?) throws -> [String: Value] {
        let wire = PeekabooMCPServer.callToolResult(from: response, toolName: toolName)
        let decoded = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(wire))
        return decoded.objectValue?["_meta"]?.objectValue ?? [:]
    }

    @MainActor
    private static func makeContext(detection: ElementDetectionResult) -> MCPToolContext {
        let automation = InspectUITestAutomationService(accessibilityGranted: true, detectionResult: detection)
        let services = PeekabooServices()
        return MCPToolContext(
            automation: automation,
            menu: services.menu,
            windows: services.windows,
            applications: services.applications,
            dialogs: services.dialogs,
            dock: services.dock,
            screenCapture: services.screenCapture,
            desktopObservation: DesktopObservationService(
                screenCapture: services.screenCapture,
                automation: automation,
                applications: services.applications,
                screens: services.screens),
            snapshots: InMemorySnapshotManager(),
            screens: services.screens,
            agent: services.agent,
            permissions: services.permissions,
            clipboard: services.clipboard,
            browser: services.browser,
            snapshotOwner: Self.uiSnapshots.owner)
    }
}
