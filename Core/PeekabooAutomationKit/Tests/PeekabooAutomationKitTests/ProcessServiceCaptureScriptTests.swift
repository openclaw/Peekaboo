import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import PeekabooAutomationKit

@available(macOS 14.0, *)
@MainActor
final class ProcessServiceCaptureScriptTests: XCTestCase {
    func testExecuteScriptReportsObservationBoundary() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-script-boundary-\(UUID().uuidString).png")
        let processService = ProcessService(
            applicationService: UnusedApplicationService(),
            screenCaptureService: StaticScreenCaptureService(),
            snapshotManager: InMemorySnapshotManager(),
            uiAutomationService: UnusedUIAutomationService(),
            windowManagementService: UnusedWindowManagementService(),
            menuService: UnusedMenuService(),
            dockService: UnusedDockService(),
            clipboardService: ClipboardService(pasteboard: NSPasteboard.withUniqueName()))
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let beforeExecution = Date()

        let results = try await processService.executeScript(
            PeekabooScript(description: nil, steps: [
                ScriptStep(stepId: "see", comment: nil, command: "see", params: .screenshot(.init(
                    path: outputURL.path,
                    mode: "frontmost",
                    annotate: false))),
            ]),
            failFast: true,
            verbose: false)

        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(results.count, 1)
        XCTAssertNotNil(result.snapshotId)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(result.startedAt), beforeExecution)
        XCTAssertLessThanOrEqual(try XCTUnwrap(result.startedAt), Date())
    }

    func testEachScriptSeeCreatesFreshSnapshotForNamedReferences() async throws {
        let firstURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-script-first-\(UUID().uuidString).png")
        let secondURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-script-second-\(UUID().uuidString).png")
        let processService = ProcessService(
            applicationService: UnusedApplicationService(),
            screenCaptureService: StaticScreenCaptureService(),
            snapshotManager: InMemorySnapshotManager(),
            uiAutomationService: UnusedUIAutomationService(),
            windowManagementService: UnusedWindowManagementService(),
            menuService: UnusedMenuService(),
            dockService: UnusedDockService(),
            clipboardService: ClipboardService(pasteboard: NSPasteboard.withUniqueName()))
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        let results = try await processService.executeScript(
            PeekabooScript(description: nil, steps: [
                ScriptStep(stepId: "first", comment: nil, command: "see", params: .screenshot(.init(
                    path: firstURL.path,
                    mode: "frontmost",
                    annotate: false))),
                ScriptStep(stepId: "second", comment: nil, command: "see", params: .screenshot(.init(
                    path: secondURL.path,
                    mode: "frontmost",
                    annotate: false))),
            ]),
            failFast: true,
            verbose: false)

        XCTAssertEqual(results.count, 2)
        XCTAssertNotEqual(try XCTUnwrap(results[0].snapshotId), try XCTUnwrap(results[1].snapshotId))
    }

    func testGenericSeeParsesPIDAndExactWindowID() throws {
        let processService = ProcessService(
            applicationService: UnusedApplicationService(),
            screenCaptureService: UnusedScreenCaptureService(),
            snapshotManager: UnusedSnapshotManager(),
            uiAutomationService: UnusedUIAutomationService(),
            windowManagementService: UnusedWindowManagementService(),
            menuService: UnusedMenuService(),
            dockService: UnusedDockService(),
            clipboardService: ClipboardService(pasteboard: NSPasteboard.withUniqueName()))

        let normalized = try processService.normalizeStepParameters(ScriptStep(
            stepId: "observe",
            comment: nil,
            command: "see",
            params: .generic([
                "pid": "4242",
                "window_id": "9001",
                "path": "/tmp/observe.png",
            ])))

        guard case let .screenshot(params) = normalized.params else {
            return XCTFail("Expected screenshot parameters")
        }
        XCTAssertEqual(params.pid, 4242)
        XCTAssertEqual(params.windowId, 9001)
    }

    func testRunRejectsMalformedAndOverflowingTargetIdentifiersBeforeCapture() async throws {
        let capture = StaticScreenCaptureService()
        let processService = ProcessService(
            applicationService: UnusedApplicationService(),
            screenCaptureService: capture,
            snapshotManager: UnusedSnapshotManager(),
            uiAutomationService: UnusedUIAutomationService(),
            windowManagementService: UnusedWindowManagementService(),
            menuService: UnusedMenuService(),
            dockService: UnusedDockService(),
            clipboardService: ClipboardService(pasteboard: NSPasteboard.withUniqueName()))
        let invalidTargets = [
            (key: "pid", value: "not-a-pid", expectedField: "pid"),
            (key: "pid", value: String(UInt64(Int32.max) + 1), expectedField: "pid"),
            (key: "window-id", value: "12.5", expectedField: "windowId"),
            (key: "window_id", value: String(UInt64(UInt32.max) + 1), expectedField: "windowId"),
        ]

        for invalidTarget in invalidTargets {
            let results = try await processService.executeScript(
                PeekabooScript(description: nil, steps: [
                    ScriptStep(
                        stepId: "invalid-target",
                        comment: nil,
                        command: "see",
                        params: .generic([
                            invalidTarget.key: invalidTarget.value,
                            "path": "/tmp/peekaboo-invalid-target-must-not-capture.png",
                        ])),
                ]),
                failFast: true,
                verbose: false)

            XCTAssertEqual(results.count, 1)
            XCTAssertFalse(results[0].success)
            XCTAssertTrue(try XCTUnwrap(results[0].error).contains("Invalid \(invalidTarget.expectedField)"))
        }

        XCTAssertEqual(capture.captureCount, 0)
    }

    func testScreenshotPathExpandsHomeDirectoryPath() async throws {
        let relativePath = "Library/Caches/peekaboo-script-shot-\(UUID().uuidString).png"
        let outputURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relativePath)
        let tildePath = "~/\(relativePath)"
        let processService = ProcessService(
            applicationService: UnusedApplicationService(),
            screenCaptureService: StaticScreenCaptureService(),
            snapshotManager: InMemorySnapshotManager(),
            uiAutomationService: UnusedUIAutomationService(),
            windowManagementService: UnusedWindowManagementService(),
            menuService: UnusedMenuService(),
            dockService: UnusedDockService(),
            clipboardService: ClipboardService(pasteboard: NSPasteboard.withUniqueName()))
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let result = try await processService.executeStep(
            ScriptStep(stepId: "shot", comment: nil, command: "see", params: .screenshot(.init(
                path: tildePath,
                mode: "frontmost",
                annotate: false))),
            snapshotId: nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertEqual(try Data(contentsOf: outputURL), StaticScreenCaptureService.imageData)
        guard case let .data(output) = result.output else {
            return XCTFail("Expected structured output")
        }
        guard case let .success(screenshotPath)? = output["screenshot_path"] else {
            return XCTFail("Expected screenshot_path output")
        }
        XCTAssertEqual(screenshotPath, outputURL.path)
    }

    func testScreenshotPathCreatesParentDirectories() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-script-shot-\(UUID().uuidString)")
            .appendingPathComponent("nested")
            .appendingPathComponent("shot.png")
        let processService = ProcessService(
            applicationService: UnusedApplicationService(),
            screenCaptureService: StaticScreenCaptureService(),
            snapshotManager: InMemorySnapshotManager(),
            uiAutomationService: UnusedUIAutomationService(),
            windowManagementService: UnusedWindowManagementService(),
            menuService: UnusedMenuService(),
            dockService: UnusedDockService(),
            clipboardService: ClipboardService(pasteboard: NSPasteboard.withUniqueName()))
        defer {
            try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent().deletingLastPathComponent())
        }

        let result = try await processService.executeStep(
            ScriptStep(stepId: "shot", comment: nil, command: "see", params: .screenshot(.init(
                path: outputURL.path,
                mode: "frontmost",
                annotate: false))),
            snapshotId: nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertEqual(try Data(contentsOf: outputURL), StaticScreenCaptureService.imageData)
        guard case let .data(output) = result.output else {
            return XCTFail("Expected structured output")
        }
        guard case let .success(screenshotPath)? = output["screenshot_path"] else {
            return XCTFail("Expected screenshot_path output")
        }
        XCTAssertEqual(screenshotPath, outputURL.path)
    }
}

@available(macOS 14.0, *)
@MainActor
private final class StaticScreenCaptureService: ScreenCaptureServiceProtocol {
    static let imageData = Data("fake screenshot".utf8)
    private(set) var captureCount = 0

    func captureScreen(
        displayIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.captureCount += 1
        return self.result(mode: .screen)
    }

    func captureWindow(
        appIdentifier _: String,
        windowIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.captureCount += 1
        return self.result(mode: .window)
    }

    func captureFrontmost(
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.captureCount += 1
        return self.result(mode: .frontmost)
    }

    func captureArea(
        _: CGRect,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.captureCount += 1
        return self.result(mode: .area)
    }

    func hasScreenRecordingPermission() async -> Bool {
        true
    }

    private func result(mode: CaptureMode) -> CaptureResult {
        CaptureResult(
            imageData: Self.imageData,
            metadata: CaptureMetadata(size: CGSize(width: 1, height: 1), mode: mode))
    }
}
