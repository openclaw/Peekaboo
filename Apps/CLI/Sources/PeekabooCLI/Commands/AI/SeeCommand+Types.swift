import CoreGraphics
import Foundation
import PeekabooCore

struct CaptureContext {
    let captureResult: CaptureResult
    let captureBounds: CGRect?
    let prefersOCR: Bool
    let ocrMethod: String?
    let windowIdOverride: Int?
}

struct MenuBarPopoverCapture {
    let captureResult: CaptureResult
    let windowBounds: CGRect
    let windowId: Int?
}

struct CaptureAndDetectionResult {
    let snapshotId: String
    let screenshotPath: String
    let annotatedPath: String?
    let elements: DetectedElements
    let metadata: DetectionMetadata
    let observation: SeeObservationDiagnostics?
}

struct SnapshotPaths {
    let raw: String
    let annotated: String
    let map: String
}

struct SeeCommandRenderContext {
    let snapshotId: String
    let screenshotPath: String
    let annotatedPath: String?
    let metadata: DetectionMetadata
    let elements: DetectedElements
    let analysis: SeeAnalysisData?
    let executionTime: TimeInterval
    let observation: SeeObservationDiagnostics?
}

struct UIElementSummary: Codable {
    let id: String
    let role: String
    let title: String?
    let label: String?
    let description: String?
    let role_description: String?
    let help: String?
    let identifier: String?
    let bounds: UIElementBounds
    let is_actionable: Bool
    let keyboard_shortcut: String?
}

struct UIElementBounds: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.size.width
        self.height = rect.size.height
    }
}

struct SeeAnalysisData: Codable {
    let provider: String
    let model: String
    let text: String
}

struct SeeObservationDiagnostics: Codable {
    let spans: [SeeObservationSpan]
    let warnings: [String]
    let state_snapshot: SeeDesktopStateSnapshotSummary?
    let target: SeeObservationTargetDiagnostics?

    init(timings: ObservationTimings, diagnostics: DesktopObservationDiagnostics) {
        self.spans = timings.spans.map(SeeObservationSpan.init)
        self.warnings = diagnostics.warnings
        self.state_snapshot = diagnostics.stateSnapshot.map(SeeDesktopStateSnapshotSummary.init)
        self.target = diagnostics.target.map(SeeObservationTargetDiagnostics.init)
    }
}

struct SeeObservationTargetDiagnostics: Codable {
    let requested_kind: String
    let resolved_kind: String
    let source: String
    let hints: [String]
    let open_if_needed: Bool
    let click_hint: String?
    let window_id: Int?
    let bounds: CGRect?
    let capture_scale_hint: CGFloat?

    init(_ diagnostics: DesktopObservationTargetDiagnostics) {
        self.requested_kind = diagnostics.requestedKind
        self.resolved_kind = diagnostics.resolvedKind
        self.source = diagnostics.source
        self.hints = diagnostics.hints
        self.open_if_needed = diagnostics.openIfNeeded
        self.click_hint = diagnostics.clickHint
        self.window_id = diagnostics.windowID
        self.bounds = diagnostics.bounds
        self.capture_scale_hint = diagnostics.captureScaleHint
    }
}

struct SeeObservationSpan: Codable {
    let name: String
    let duration_ms: Double
    let metadata: [String: String]

    init(_ span: ObservationSpan) {
        self.name = span.name
        self.duration_ms = span.durationMS
        self.metadata = span.metadata
    }
}

struct SeeDesktopStateSnapshotSummary: Codable {
    let display_count: Int
    let running_application_count: Int
    let window_count: Int
    let frontmost_application_name: String?
    let frontmost_bundle_identifier: String?
    let frontmost_window_title: String?
    let frontmost_window_id: Int?

    init(_ summary: DesktopStateSnapshotSummary) {
        self.display_count = summary.displayCount
        self.running_application_count = summary.runningApplicationCount
        self.window_count = summary.windowCount
        self.frontmost_application_name = summary.frontmostApplication?.name
        self.frontmost_bundle_identifier = summary.frontmostApplication?.bundleIdentifier
        self.frontmost_window_title = summary.frontmostWindow?.title
        self.frontmost_window_id = summary.frontmostWindow?.windowID
    }
}

struct SeeTruncationSummary: Codable {
    let max_depth_reached: Bool
    let max_element_count_reached: Bool
    let max_children_per_node_reached: Bool
    let warning: String

    init?(metadata: DetectionMetadata) {
        guard let truncationInfo = metadata.truncationInfo, truncationInfo.isTruncated else {
            return nil
        }
        self.max_depth_reached = truncationInfo.maxDepthReached
        self.max_element_count_reached = truncationInfo.maxElementCountReached
        self.max_children_per_node_reached = truncationInfo.maxChildrenPerNodeReached
        self.warning = truncationInfo.remediationMessage(budget: metadata.windowContext?.traversalBudget)
    }
}

struct SeeResult: Codable {
    let snapshot_id: String
    let screenshot_raw: String
    let screenshot_annotated: String
    let ui_map: String
    let application_name: String?
    let window_title: String?
    let is_dialog: Bool
    let element_count: Int
    let interactable_count: Int
    let capture_mode: String
    let analysis: SeeAnalysisData?
    let execution_time: TimeInterval
    let ui_elements: [UIElementSummary]
    let truncation: SeeTruncationSummary?
    let menu_bar: MenuBarSummary?
    let observation: SeeObservationDiagnostics?
    var success: Bool = true

    init(
        snapshot_id: String,
        screenshot_raw: String,
        screenshot_annotated: String,
        ui_map: String,
        application_name: String?,
        window_title: String?,
        is_dialog: Bool,
        element_count: Int,
        interactable_count: Int,
        capture_mode: String,
        analysis: SeeAnalysisData?,
        execution_time: TimeInterval,
        ui_elements: [UIElementSummary],
        menu_bar: MenuBarSummary?,
        truncation: SeeTruncationSummary? = nil,
        observation: SeeObservationDiagnostics? = nil,
        success: Bool = true
    ) {
        self.snapshot_id = snapshot_id
        self.screenshot_raw = screenshot_raw
        self.screenshot_annotated = screenshot_annotated
        self.ui_map = ui_map
        self.application_name = application_name
        self.window_title = window_title
        self.is_dialog = is_dialog
        self.element_count = element_count
        self.interactable_count = interactable_count
        self.capture_mode = capture_mode
        self.analysis = analysis
        self.execution_time = execution_time
        self.ui_elements = ui_elements
        self.truncation = truncation
        self.menu_bar = menu_bar
        self.observation = observation
        self.success = success
    }
}

struct MenuBarSummary: Codable {
    let menus: [MenuSummary]

    struct MenuSummary: Codable {
        let title: String
        let item_count: Int
        let enabled: Bool
        let items: [MenuItemSummary]
    }

    struct MenuItemSummary: Codable {
        let title: String
        let enabled: Bool
        let keyboard_shortcut: String?
    }
}
