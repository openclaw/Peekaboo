import AppKit
import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore
@testable import PeekabooVisualizer

@Suite(.serialized, .tags(.safe))
struct UIAutomationServiceEnhancedTests {
    @Test
    func `Element coordinates are transformed to window-relative`() {
        // Given screen coordinates for elements
        let screenElements = [
            MockElement(frame: CGRect(x: 500, y: 300, width: 100, height: 50), role: "AXButton"),
            MockElement(frame: CGRect(x: 600, y: 350, width: 150, height: 30), role: "AXTextField"),
            MockElement(frame: CGRect(x: 450, y: 400, width: 200, height: 40), role: "AXLink"),
        ]

        // And window bounds
        let windowBounds = CGRect(x: 400, y: 250, width: 800, height: 600)

        // When processing elements with window bounds
        var transformedFrames: [CGRect] = []
        for element in screenElements {
            var frame = element.frame
            // Simulate the transformation in processElement
            if windowBounds != .zero {
                frame.origin.x -= windowBounds.origin.x
                frame.origin.y -= windowBounds.origin.y
            }
            transformedFrames.append(frame)
        }

        // Then coordinates should be window-relative
        #expect(transformedFrames[0].origin.x == 100) // 500 - 400
        #expect(transformedFrames[0].origin.y == 50) // 300 - 250
        #expect(transformedFrames[1].origin.x == 200) // 600 - 400
        #expect(transformedFrames[1].origin.y == 100) // 350 - 250
        #expect(transformedFrames[2].origin.x == 50) // 450 - 400
        #expect(transformedFrames[2].origin.y == 150) // 400 - 250
    }

    @Test
    func `Elements without valid bounds are skipped`() {
        // Elements with invalid bounds that should be skipped
        let invalidElements = [
            MockElement(frame: CGRect(x: 0, y: 0, width: 0, height: 50), role: "AXButton"), // Zero width
            MockElement(frame: CGRect(x: 100, y: 100, width: 50, height: 0), role: "AXButton"), // Zero height
            MockElement(frame: CGRect.zero, role: "AXButton"), // Zero rect
        ]

        // Valid element
        let validElement = MockElement(frame: CGRect(x: 100, y: 100, width: 50, height: 30), role: "AXButton")

        var processedCount = 0
        for element in invalidElements + [validElement] {
            // Skip elements without valid bounds (as done in processElement)
            guard element.frame.width > 0, element.frame.height > 0 else {
                continue
            }
            processedCount += 1
        }

        // Only the valid element should be processed
        #expect(processedCount == 1)
    }

    @Test
    func `Front window is selected when no window title specified`() {
        // This tests the logic in buildUIMap
        let mockWindows = [
            MockElement(frame: CGRect(x: 0, y: 0, width: 800, height: 600), role: "AXWindow", title: "Front Window"),
            MockElement(frame: CGRect(x: 100, y: 100, width: 800, height: 600), role: "AXWindow", title: "Back Window"),
        ]

        // When no window title is specified, first window (frontmost) should be selected
        let selectedWindows: [MockElement] = if let windowTitle: String? = nil {
            // Find specific window by title
            mockWindows.filter { $0.title == windowTitle }
        } else {
            // Process only the frontmost window
            if let frontWindow = mockWindows.first {
                [frontWindow]
            } else {
                []
            }
        }

        #expect(selectedWindows.count == 1)
        #expect(selectedWindows.first?.title == "Front Window")
    }

    @Test
    func `Specific window is selected when title is provided`() {
        let mockWindows = [
            MockElement(frame: CGRect(x: 0, y: 0, width: 800, height: 600), role: "AXWindow", title: "Window A"),
            MockElement(frame: CGRect(x: 100, y: 100, width: 800, height: 600), role: "AXWindow", title: "Window B"),
            MockElement(frame: CGRect(x: 200, y: 200, width: 800, height: 600), role: "AXWindow", title: "Window C"),
        ]

        // When specific window title is provided
        let targetTitle = "Window B"
        let selectedWindows = mockWindows.filter { $0.title == targetTitle }

        #expect(selectedWindows.count == 1)
        #expect(selectedWindows.first?.title == "Window B")
    }

    @Test
    func `Role-based ID prefixes are assigned correctly`() {
        // Test the ID prefix logic
        let testCases: [(ElementType, String)] = [
            (.button, "B"),
            (.textField, "T"),
            (.link, "L"),
            (.image, "I"),
            (.group, "G"),
            (.slider, "S"),
            (.checkbox, "C"),
            (.menu, "M"),
            (.other, "O"),
        ]

        for (elementType, expectedPrefix) in testCases {
            let prefix = idPrefixForType(elementType)
            #expect(prefix == expectedPrefix)
        }
    }

    @Test
    func `Element type is determined from role correctly`() {
        let roleMappings: [(String, ElementType)] = [
            ("AXButton", .button),
            ("AXTextField", .textField),
            ("AXLink", .link),
            ("AXImage", .image),
            ("AXGroup", .group),
            ("AXSlider", .slider),
            ("AXCheckBox", .checkbox),
            ("AXMenu", .menu),
            ("AXUnknown", .other),
            ("AXStaticText", .other),
        ]

        for (role, expectedType) in roleMappings {
            let elementType = elementTypeFromRole(role)
            #expect(elementType == expectedType)
        }
    }
}

// MARK: - Helper Functions (matching UIAutomationServiceEnhanced)

private func idPrefixForType(_ type: ElementType) -> String {
    switch type {
    case .button: "B"
    case .textField: "T"
    case .link: "L"
    case .image: "I"
    case .group: "G"
    case .slider: "S"
    case .checkbox: "C"
    case .menu, .menuItem: "M"
    case .staticText: "T"
    case .radioButton: "R"
    case .window: "W"
    case .dialog: "D"
    case .other: "O"
    }
}

private func elementTypeFromRole(_ role: String) -> ElementType {
    switch role {
    case "AXButton": .button
    case "AXTextField", "AXTextArea": .textField
    case "AXLink": .link
    case "AXImage": .image
    case "AXGroup": .group
    case "AXSlider": .slider
    case "AXCheckBox": .checkbox
    case "AXMenu", "AXMenuBar", "AXMenuBarItem", "AXMenuItem": .menu
    default: .other
    }
}

// MARK: - Mock Classes

struct MockElement {
    let frame: CGRect
    let role: String
    let title: String?

    init(frame: CGRect, role: String, title: String? = nil) {
        self.frame = frame
        self.role = role
        self.title = title
    }
}

@MainActor
private final class MockSnapshotManager: SnapshotManagerProtocol {
    private var mockDetectionResult: ElementDetectionResult?
    private var storedResults: [String: ElementDetectionResult] = [:]

    func primeDetectionResult(_ result: ElementDetectionResult?) {
        self.mockDetectionResult = result
    }

    func createSnapshot() async throws -> String {
        "test-snapshot-\(UUID().uuidString)"
    }

    func storeDetectionResult(snapshotId: String, result: ElementDetectionResult) async throws {
        self.storedResults[snapshotId] = result
    }

    func getDetectionResult(snapshotId: String) async throws -> ElementDetectionResult? {
        self.mockDetectionResult ?? self.storedResults[snapshotId]
    }

    func getMostRecentSnapshot() async -> String? {
        self.storedResults.keys.first
    }

    func getMostRecentSnapshot(applicationBundleId _: String) async -> String? {
        self.storedResults.keys.first
    }

    func invalidateImplicitLatestSnapshot() async throws -> String? {
        nil
    }

    func listSnapshots() async throws -> [SnapshotInfo] {
        []
    }

    func cleanSnapshot(snapshotId: String) async throws {
        self.storedResults.removeValue(forKey: snapshotId)
    }

    func cleanSnapshotsOlderThan(days: Int) async throws -> Int {
        let count = self.storedResults.count
        self.storedResults.removeAll()
        return count
    }

    func cleanAllSnapshots() async throws -> Int {
        let count = self.storedResults.count
        self.storedResults.removeAll()
        return count
    }

    nonisolated func getSnapshotStoragePath() -> String {
        "/tmp/test-snapshots"
    }

    func storeScreenshot(_ request: SnapshotScreenshotRequest) async throws {
        // No-op for tests
        _ = request
    }

    func storeAnnotatedScreenshot(snapshotId: String, annotatedScreenshotPath: String) async throws {
        _ = snapshotId
        _ = annotatedScreenshotPath
    }

    func getElement(snapshotId: String, elementId: String) async throws -> UIElement? {
        nil
    }

    func findElements(snapshotId: String, matching query: String) async throws -> [UIElement] {
        []
    }

    func getUIAutomationSnapshot(snapshotId: String) async throws -> UIAutomationSnapshot? {
        nil
    }
}
