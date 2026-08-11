import Foundation
import MCP
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

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
    func `MCP live cadence rejects out of range and inverted rates`() async {
        let windows = CaptureWindowResolverWindowService(windows: [])
        for arguments: [String: Value] in [
            ["source": .string("live"), "idle_fps": .double(0)],
            ["source": .string("live"), "idle_fps": .double(5.1)],
            ["source": .string("live"), "active_fps": .double(0.4)],
            ["source": .string("live"), "active_fps": .double(15.1)],
            ["source": .string("live"), "idle_fps": .double(5), "active_fps": .double(4)],
        ] {
            await #expect(throws: PeekabooError.self) {
                _ = try await CaptureRequest(arguments: ToolArguments(value: .object(arguments)), windows: windows)
            }
        }
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

    @Test
    func `no-valid-frame MCP response preserves retry and focus effect honesty`() throws {
        let error = CaptureNoValidFramesError(
            source: .video,
            framesDropped: 3,
            decodeFailures: 3,
            firstDecodeError: "first",
            lastDecodeError: "last",
            lastCaptureError: nil)

        let background = CaptureTool.failureResponse(error, mutationDispatched: false)
        let backgroundMeta = try #require(Self.meta(from: background))
        #expect(background.isError)
        #expect(backgroundMeta["error_code"] == .string("CAPTURE_NO_VALID_FRAMES"))
        #expect(backgroundMeta["retry_safe"] == .bool(true))
        #expect(backgroundMeta["mutation_dispatched"] == .bool(false))
        #expect(backgroundMeta["effect"] == nil)
        #expect(backgroundMeta["decode_failures"] == .int(3))

        let foreground = CaptureTool.failureResponse(error, mutationDispatched: true)
        let foregroundMeta = try #require(Self.meta(from: foreground))
        #expect(foregroundMeta["effect"] == .string("partial"))
        #expect(foregroundMeta["mutation_dispatched"] == .bool(true))
        #expect(foregroundMeta["retry_safe"] == .bool(false))
    }

    @Test
    func `all MCP capture failures preserve actual focus dispatch receipts`() throws {
        let error = PeekabooError.fileIOError("metadata write failed")
        let background = CaptureTool.failureResponse(error, mutationDispatched: false)
        let foreground = CaptureTool.failureResponse(error, mutationDispatched: true)
        let backgroundMeta = try #require(Self.meta(from: background))
        let foregroundMeta = try #require(Self.meta(from: foreground))

        #expect(background.isError)
        #expect(backgroundMeta["mutation_dispatched"] == .bool(false))
        #expect(backgroundMeta["retry_safe"] == .bool(true))
        #expect(backgroundMeta["effect"] == nil)
        #expect(foreground.isError)
        #expect(foregroundMeta["mutation_dispatched"] == .bool(true))
        #expect(foregroundMeta["retry_safe"] == .bool(false))
        #expect(foregroundMeta["effect"] == .string("partial"))
    }

    @Test
    @MainActor
    func `capture request setup failure returns explicit pre-dispatch receipt`() async throws {
        let response = try await CaptureTool(context: MCPToolContext(services: PeekabooServices())).execute(
            arguments: ToolArguments(raw: ["source": "camera"]))
        let meta = try #require(Self.meta(from: response))

        #expect(response.isError)
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(true))
        #expect(meta["effect"] == nil)
    }

    @Test
    @MainActor
    func `partial focus failure returns conservative capture dispatch receipt`() async throws {
        let focusError = PeekabooError.operationError(message: "focus verification failed after dispatch")
        let windows = CaptureWindowResolverWindowService(
            windows: [Self.window(id: 42, title: "Main Document", index: 0)],
            focusError: focusError)
        let services = PeekabooServices()
        let context = MCPToolContext(
            automation: services.automation,
            menu: services.menu,
            windows: windows,
            applications: services.applications,
            dialogs: services.dialogs,
            dock: services.dock,
            screenCapture: services.screenCapture,
            desktopObservation: services.desktopObservation,
            snapshots: services.snapshots,
            screens: services.screens,
            agent: services.agent,
            permissions: services.permissions,
            clipboard: services.clipboard,
            browser: services.browser)
        let response = try await CaptureTool(context: context).execute(arguments: ToolArguments(raw: [
            "source": "live",
            "mode": "window",
            "app": "TextEdit",
            "window_title": "Main Document",
            "capture_focus": "foreground",
        ]))
        let meta = try #require(Self.meta(from: response))

        #expect(response.isError)
        #expect(windows.focusCallCount == 1)
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["effect"] == .string("partial"))
    }

    @Test
    @MainActor
    func `successful image response reports actual focus dispatch`() throws {
        let tool = ImageTool(context: MCPToolContext(services: PeekabooServices()))
        let background = tool.buildCaptureResponse(
            format: .png,
            savedFiles: [],
            captureResults: [],
            observation: nil,
            mutationDispatched: false)
        let foreground = tool.buildCaptureResponse(
            format: .png,
            savedFiles: [],
            captureResults: [],
            observation: nil,
            mutationDispatched: true)
        let backgroundMeta = try #require(Self.meta(from: background))
        let foregroundMeta = try #require(Self.meta(from: foreground))

        #expect(backgroundMeta["mutation_dispatched"] == .bool(false))
        #expect(backgroundMeta["retry_safe"] == .bool(true))
        #expect(backgroundMeta["effect"] == nil)
        #expect(foregroundMeta["mutation_dispatched"] == .bool(true))
        #expect(foregroundMeta["retry_safe"] == .bool(false))
        #expect(foregroundMeta["effect"] == nil)
    }

    private static func meta(from response: ToolResponse) -> [String: Value]? {
        guard case let .object(meta) = response.meta else { return nil }
        return meta
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
    let focusError: (any Error)?
    var requestedTargets: [WindowTarget] = []
    var focusCallCount = 0

    init(windows: [ServiceWindowInfo], focusError: (any Error)? = nil) {
        self.windows = windows
        self.focusError = focusError
    }

    func closeWindow(target _: WindowTarget) async throws {}

    func minimizeWindow(target _: WindowTarget) async throws {}

    func maximizeWindow(target _: WindowTarget) async throws {}

    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {}

    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {}

    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {}

    func focusWindow(target _: WindowTarget) async throws {
        self.focusCallCount += 1
        if let focusError {
            throw focusError
        }
    }

    func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo] {
        self.requestedTargets.append(target)
        return self.windows
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }
}
