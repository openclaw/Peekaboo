import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
struct DesktopObservationFreshnessTests {
    @Test
    func `default detection encoding preserves legacy canonical bytes`() throws {
        struct LegacyOptions: Encodable {
            let mode: DetectionMode
            let allowWebFocusFallback: Bool
            let includeMenuBarElements: Bool
            let preferOCR: Bool
            let traversalBudget: AXTraversalBudget
        }
        let options = DesktopDetectionOptions()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let legacy = try encoder.encode(LegacyOptions(
            mode: options.mode,
            allowWebFocusFallback: options.allowWebFocusFallback,
            includeMenuBarElements: options.includeMenuBarElements,
            preferOCR: options.preferOCR,
            traversalBudget: options.traversalBudget))
        #expect(try encoder.encode(options) == legacy)
        #expect(try JSONDecoder().decode(DesktopDetectionOptions.self, from: legacy) == options)
        var fresh = options
        fresh.requiresFreshAccessibilityTree = true
        let encoded = try encoder.encode(fresh)
        #expect(try #require(String(data: encoded, encoding: .utf8))
            .contains("\"requiresFreshAccessibilityTree\":true"))
        #expect(try JSONDecoder().decode(DesktopDetectionOptions.self, from: encoded) == fresh)
    }

    @Test(arguments: ["AXorcist", "AXorcist+OCR", "AXorcist (cached)", "AXorcist (cached)+OCR", "OCR", "fixture"])
    func `freshness uses known native cache evidence and explicit request acknowledgement`(method: String) {
        let metadata = Self.metadata(method: method, acknowledged: true)
        let cached = method.contains("(cached)")
        let native = method == "AXorcist" || method == "AXorcist+OCR"
        #expect(metadata.usedAccessibilityCache == (cached ? true : native ? false : nil))
        #expect((DesktopObservationEvidencePolicy.freshAccessibilityEvidenceError(metadata, requested: true) == nil)
            == native)
        #expect(DesktopObservationEvidencePolicy.freshAccessibilityEvidenceError(metadata, requested: false) == nil)
        #expect(DesktopObservationEvidencePolicy.freshAccessibilityEvidenceError(
            Self.metadata(method: method, acknowledged: false), requested: true) != nil)
    }

    @Test
    func `cache warnings override a nominal uncached method and missing evidence stays unknown`() {
        let metadata = Self.metadata(method: "AXorcist", acknowledged: true, warnings: ["ax_cache_hit"])
        #expect(metadata.usedAccessibilityCache == true)
        #expect(DesktopObservationEvidencePolicy.freshAccessibilityEvidenceError(metadata, requested: true) != nil)
        #expect(DesktopObservationEvidencePolicy.freshAccessibilityEvidenceError(nil, requested: true) != nil)
        #expect(DesktopObservationEvidencePolicy.freshAccessibilityEvidenceError(nil, requested: false) == nil)
    }

    @Test(arguments: [false, true])
    @MainActor
    func `observation forwards freshness without changing partial evidence authority`(fresh: Bool) async throws {
        let metadata = Self.metadata(method: "AXorcist", acknowledged: fresh)
        let detection = ElementDetectionResult(
            snapshotId: "fresh-fixture",
            screenshotPath: "",
            elements: DetectedElements(buttons: [.init(id: "B1", type: .button, label: "Fixture", bounds: .zero)]),
            metadata: metadata)
        let automation = RecordingUIAutomationService(fixedResult: detection)
        let capture = RecordingScreenCaptureService(result: Self.capture)
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: automation,
            applications: RecordingApplicationService(applications: [], windows: []))
        let result = try await service.observe(DesktopObservationRequest(
            target: .screen(index: 0),
            detection: .init(requiresFreshAccessibilityTree: fresh)))
        #expect(automation.lastWindowContext?.requiresFreshAccessibilityTree == fresh)
        #expect(result.elements?.metadata.usedAccessibilityCache == false)
        #expect(result.elements?.metadata.truncationInfo?.isTruncated == true)
        #expect(result.elements?.elements.all.count == 1)
    }

    @Test
    @MainActor
    func `pixel only freshness refuses before capture or detection`() async {
        let automation = RecordingUIAutomationService()
        let capture = RecordingScreenCaptureService(result: Self.capture)
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: automation,
            applications: RecordingApplicationService(applications: [], windows: []))
        await #expect(throws: PeekabooError.self) {
            try await service.observe(DesktopObservationRequest(
                target: .screen(index: 0),
                detection: .init(mode: .none, requiresFreshAccessibilityTree: true)))
        }
        #expect(capture.operations.isEmpty)
        #expect(automation.detectCalls == 0)
    }

    @Test(arguments: ["AXorcist (cached)", "unknown", "ignored"])
    @MainActor
    func `unproven freshness cannot publish a reusable service snapshot`(method: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fresh-refusal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = InMemorySnapshotManager()
        let detection = ElementDetectionResult(
            snapshotId: "unproven-fresh",
            screenshotPath: "",
            elements: DetectedElements(buttons: [.init(id: "B1", type: .button, label: "Fixture", bounds: .zero)]),
            metadata: Self.metadata(
                method: method == "ignored" ? "AXorcist" : method,
                acknowledged: method != "ignored"))
        let automation = RecordingUIAutomationService(fixedResult: detection)
        let service = DesktopObservationService(
            screenCapture: RecordingScreenCaptureService(result: Self.capture),
            automation: automation,
            applications: RecordingApplicationService(applications: [], windows: []),
            snapshotManager: snapshots)
        await #expect(throws: PeekabooError.self) {
            try await service.observe(DesktopObservationRequest(
                target: .screen(index: 0),
                detection: .init(requiresFreshAccessibilityTree: true),
                output: .init(path: root.appendingPathComponent("capture.png").path, saveSnapshot: true)))
        }
        #expect(automation.lastWindowContext?.requiresFreshAccessibilityTree == true)
        #expect(try await snapshots.listSnapshots().isEmpty)
        #expect(await snapshots.getMostRecentSnapshot() == nil)
    }

    private static var capture: CaptureResult {
        CaptureResult(
            imageData: Data([1]),
            metadata: CaptureMetadata(size: CGSize(width: 20, height: 20), mode: .screen))
    }

    private static func metadata(method: String, acknowledged: Bool, warnings: [String] = []) -> DetectionMetadata {
        DetectionMetadata(
            detectionTime: 0,
            elementCount: 1,
            method: method,
            warnings: warnings,
            windowContext: WindowContext(requiresFreshAccessibilityTree: acknowledged),
            truncationInfo: DetectionTruncationInfo(deadlineReached: true))
    }
}
