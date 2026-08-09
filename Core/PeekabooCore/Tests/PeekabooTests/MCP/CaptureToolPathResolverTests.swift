import Foundation
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

struct CaptureToolPathResolverTests {
    @Test
    func `output directory expands tilde`() {
        let url = CaptureToolPathResolver.outputDirectory(from: "~/Desktop/peekaboo-capture")

        #expect(url.path == NSString(string: "~/Desktop/peekaboo-capture").expandingTildeInPath)
    }

    @Test
    func `video file paths expand tilde`() {
        let inputURL = CaptureToolPathResolver.fileURL(from: "~/Movies/input.mov")
        let outputPath = CaptureToolPathResolver.filePath(from: "~/Desktop/output.mp4")

        #expect(inputURL.path == NSString(string: "~/Movies/input.mov").expandingTildeInPath)
        #expect(outputPath == NSString(string: "~/Desktop/output.mp4").expandingTildeInPath)
    }

    @Test
    func `argument resolver validates source mode and aliases`() throws {
        #expect(try CaptureToolArgumentResolver.source(from: nil) == .live)
        #expect(try CaptureToolArgumentResolver.mode(
            from: nil,
            hasRegion: true,
            hasWindowTarget: false) == .area)
        #expect(try CaptureToolArgumentResolver.mode(
            from: "region",
            hasRegion: false,
            hasWindowTarget: false) == .area)
        #expect(CaptureToolArgumentResolver.applicationIdentifier(app: nil, pid: 123) == "PID:123")

        #expect(throws: PeekabooError.self) {
            _ = try CaptureToolArgumentResolver.source(from: "camera")
        }
        #expect(throws: PeekabooError.self) {
            _ = try CaptureToolArgumentResolver.mode(
                from: "banana",
                hasRegion: false,
                hasWindowTarget: false)
        }
    }

    @Test
    func `argument resolver validates region diff strategy and capture focus`() throws {
        #expect(try CaptureToolArgumentResolver.region(from: "1, 2, 30, 40") == CGRect(
            x: 1,
            y: 2,
            width: 30,
            height: 40))
        #expect(try CaptureToolArgumentResolver.diffStrategy(from: nil) == .fast)
        #expect(try CaptureToolArgumentResolver.captureFocus(from: nil) == .background)
        #expect(try CaptureToolArgumentResolver.captureFocus(from: "foreground") == .foreground)

        #expect(throws: PeekabooError.self) {
            _ = try CaptureToolArgumentResolver.region(from: "1,two,30,40")
        }
        #expect(throws: PeekabooError.self) {
            _ = try CaptureToolArgumentResolver.region(from: "1,2,0,40")
        }
        #expect(throws: PeekabooError.self) {
            _ = try CaptureToolArgumentResolver.diffStrategy(from: "slow")
        }
        #expect(throws: PeekabooError.self) {
            _ = try CaptureToolArgumentResolver.captureFocus(from: "middle")
        }
    }

    @Test
    func `request decodes snake case MCP capture options`() async throws {
        let windows = CaptureWindowResolverWindowService(windows: [])

        let request = try await CaptureRequest(arguments: ToolArguments(raw: [
            "source": "live",
            "mode": "area",
            "region": "1,2,30,40",
            "duration_seconds": 2.5,
            "idle_fps": 0.5,
            "active_fps": 3.0,
            "threshold_percent": 0.25,
            "heartbeat_sec": 0,
            "quiet_ms": 250,
            "capture_focus": "background",
            "highlight_changes": true,
            "max_frames": 3,
            "max_mb": 1,
            "resolution_cap": 320,
            "diff_strategy": "quality",
            "diff_budget_ms": 12,
            "output_dir": "~/Desktop/mcp-capture",
            "autoclean_minutes": 5,
            "video_out": "~/Desktop/mcp-capture.mp4",
        ]), windows: windows)

        #expect(request.source == .live)
        #expect(request.scope.kind == .region)
        #expect(request.scope.region == CGRect(x: 1, y: 2, width: 30, height: 40))
        #expect(request.options.duration == 2.5)
        #expect(request.options.idleFps == 0.5)
        #expect(request.options.activeFps == 3.0)
        #expect(request.options.changeThresholdPercent == 0.25)
        #expect(request.options.heartbeatSeconds == 0)
        #expect(request.options.quietMsToIdle == 250)
        #expect(request.options.captureFocus == .background)
        #expect(request.options.highlightChanges)
        #expect(request.options.maxFrames == 3)
        #expect(request.options.maxMegabytes == 1)
        #expect(request.options.resolutionCap == 320)
        #expect(request.options.diffStrategy == .quality)
        #expect(request.options.diffBudgetMs == 12)
        #expect(request.outputDirectory.path == NSString(string: "~/Desktop/mcp-capture").expandingTildeInPath)
        #expect(request.autocleanMinutes == 5)
        #expect(request.videoOut == NSString(string: "~/Desktop/mcp-capture.mp4").expandingTildeInPath)
    }

    @Test
    func `window resolver maps app title selection to stable window id`() async throws {
        let windows = CaptureWindowResolverWindowService(windows: [
            Self.window(id: 7, title: "", index: 0, bounds: CGRect(x: 0, y: 0, width: 500, height: 30)),
            Self.window(id: 42, title: "Main Document", index: 1),
        ])

        let scope = try await CaptureToolWindowResolver.scope(
            app: "Preview",
            pid: nil,
            windowTitle: "main",
            windowIndex: nil,
            windows: windows)

        #expect(scope.kind == .window)
        #expect(scope.windowId == 42)
        #expect(scope.applicationIdentifier == "Preview")
        #expect(scope.windowIndex == 1)
        #expect(windows.requestedTargets.map(\.description) == ["application(Preview)"])
    }

    @Test
    func `window resolver maps title-only selection to stable window id`() async throws {
        let windows = CaptureWindowResolverWindowService(windows: [
            Self.window(id: 99, title: "Inspector", index: 4),
        ])

        let scope = try await CaptureToolWindowResolver.scope(
            app: nil,
            pid: nil,
            windowTitle: "Inspector",
            windowIndex: nil,
            windows: windows)

        #expect(scope.windowId == 99)
        #expect(scope.applicationIdentifier == "frontmost")
        #expect(windows.requestedTargets.map(\.description) == ["title(Inspector)"])
    }

    @Test
    func `window resolver rejects index without app or pid`() async {
        let windows = CaptureWindowResolverWindowService(windows: [
            Self.window(id: 99, title: "Inspector", index: 4),
        ])

        await #expect(throws: PeekabooError.self) {
            _ = try await CaptureToolWindowResolver.scope(
                app: nil,
                pid: nil,
                windowTitle: nil,
                windowIndex: 4,
                windows: windows)
        }
    }

    private static func window(
        id: Int,
        title: String,
        index: Int,
        bounds: CGRect = CGRect(x: 0, y: 0, width: 500, height: 400)) -> ServiceWindowInfo
    {
        ServiceWindowInfo(
            windowID: id,
            title: title,
            bounds: bounds,
            index: index)
    }
}

private final class CaptureWindowResolverWindowService: WindowManagementServiceProtocol, @unchecked Sendable {
    let windows: [ServiceWindowInfo]
    var requestedTargets: [WindowTarget] = []

    init(windows: [ServiceWindowInfo]) {
        self.windows = windows
    }

    func closeWindow(target _: WindowTarget) async throws {}

    func minimizeWindow(target _: WindowTarget) async throws {}

    func maximizeWindow(target _: WindowTarget) async throws {}

    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {}

    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {}

    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {}

    func focusWindow(target _: WindowTarget) async throws {}

    func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo] {
        self.requestedTargets.append(target)
        return self.windows
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }
}
