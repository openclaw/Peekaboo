import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

#if !PEEKABOO_SKIP_AUTOMATION
@Suite(.serialized, .tags(.imageCapture, .unit))
@MainActor
struct ImageCommandTests {
    // MARK: - Test Data & Helpers

    // MARK: - Command Parsing Tests

    @Test(.tags(.fast))
    func `Basic command parsing with defaults`() throws {
        // Test basic command parsing
        let command = try ImageCommand.parse([])

        // Verify defaults
        #expect(command.mode == nil)
        #expect(command.format == .png)
        #expect(command.path == nil)
        #expect(command.app == nil)
        #expect(command.captureFocus == .background)
        #expect(command.retina == false)
        #expect(command.jsonOutput == false)
    }

    @Test(.tags(.fast))
    func `Command with screen mode`() throws {
        // Test screen capture mode
        let command = try ImageCommand.parse(["--mode", "screen"])

        #expect(command.mode == .screen)
    }

    @Test(.tags(.fast))
    func `Command with app specifier`() throws {
        // Test app-specific capture
        let command = try ImageCommand.parse([
            "--app", "Finder",
        ])

        #expect(command.mode == nil) // mode is optional
        #expect(command.app == "Finder")
    }

    @Test(.tags(.fast))
    func `Command with PID specifier`() throws {
        // Test PID-specific capture
        let command = try ImageCommand.parse([
            "--app", "PID:1234",
        ])

        #expect(command.mode == nil) // mode is optional
        #expect(command.app == "PID:1234")
    }

    @Test(.tags(.fast))
    func `Command with window title`() throws {
        // Test window title capture
        let command = try ImageCommand.parse([
            "--window-title", "Documents",
        ])

        #expect(command.windowTitle == "Documents")
    }

    @Test(.tags(.fast))
    func `Command with output path`() throws {
        // Test output path specification
        let outputPath = "/tmp/test-images"
        let command = try ImageCommand.parse([
            "--path", outputPath,
        ])

        #expect(command.path == outputPath)
    }

    @Test(.tags(.fast))
    func `Command infers format from output path extension`() throws {
        let command = try ImageCommand.parse([
            "--path", "/tmp/test.jpg",
        ])
        #expect(command.format == .jpg)

        let commandJPEG = try ImageCommand.parse([
            "--path", "/tmp/test.jpeg",
        ])
        #expect(commandJPEG.format == .jpg)

        let commandPNG = try ImageCommand.parse([
            "--path", "/tmp/test.png",
        ])
        #expect(commandPNG.format == .png)
    }

    @Test(.tags(.fast))
    func `Command rejects conflicting format and output path extension`() {
        #expect(throws: (any Error).self) {
            try CLIOutputCapture.suppressStderr {
                _ = try ImageCommand.parse([
                    "--format", "jpg",
                    "--path", "/tmp/test.png",
                ])
            }
        }
        #expect(throws: (any Error).self) {
            try CLIOutputCapture.suppressStderr {
                _ = try ImageCommand.parse([
                    "--format", "png",
                    "--path", "/tmp/test.jpg",
                ])
            }
        }
    }

    @Test(.tags(.fast))
    func `Command with format option`() throws {
        // Test format specification
        let command = try ImageCommand.parse([
            "--format", "jpg",
        ])

        #expect(command.format == .jpg)
    }

    @Test(.tags(.fast))
    func `Command with focus option`() throws {
        // Test focus option
        let command = try ImageCommand.parse([
            "--capture-focus", "foreground",
        ])

        #expect(command.captureFocus == .foreground)
    }

    @Test(.tags(.fast))
    func `Command with JSON output`() throws {
        // Test JSON output flag
        let command = try ImageCommand.parse([
            "--json",
        ])

        #expect(command.jsonOutput == true)
    }

    @Test(.tags(.fast))
    func `Command with multi mode`() throws {
        // Test multi capture mode
        let command = try ImageCommand.parse([
            "--mode", "multi",
        ])

        #expect(command.mode == .multi)
    }

    @Test(.tags(.fast))
    func `Command with screen index`() throws {
        // Test screen index specification
        let command = try ImageCommand.parse([
            "--screen-index", "1",
        ])

        #expect(command.screenIndex == 1)
    }

    @Test(.tags(.fast))
    func `Command with analyze option`() throws {
        // Test analyze option parsing
        let command = try ImageCommand.parse([
            "--analyze", "What is shown in this image?",
        ])

        #expect(command.analyze == "What is shown in this image?")
    }

    @Test(.tags(.fast))
    func `Command with analyze and app`() throws {
        // Test analyze with app specification
        let command = try ImageCommand.parse([
            "--app", "Safari",
            "--analyze", "Summarize this webpage",
        ])

        #expect(command.app == "Safari")
        #expect(command.analyze == "Summarize this webpage")
    }

    @Test(.tags(.fast))
    func `Command with analyze and mode`() throws {
        // Test analyze with different capture modes
        let command = try ImageCommand.parse([
            "--mode", "frontmost",
            "--analyze", "What errors are shown?",
        ])

        #expect(command.mode == .frontmost)
        #expect(command.analyze == "What errors are shown?")
    }

    @Test(.tags(.fast))
    func `Command with analyze and JSON output`() throws {
        // Test analyze with JSON output
        let command = try ImageCommand.parse([
            "--analyze", "Describe the UI",
            "--json",
        ])

        #expect(command.analyze == "Describe the UI")
        #expect(command.jsonOutput == true)
    }

    @Test(.tags(.fast))
    func `Command with retina flag`() throws {
        let command = try ImageCommand.parse(["--retina"])

        #expect(command.retina == true)
    }

    // MARK: - Parameterized Command Tests

    @Test(
        arguments: [
            (args: ["--mode", "screen", "--format", "png"], mode: CaptureMode.screen, format: ImageFormat.png),
            (args: ["--mode", "window", "--format", "jpg"], mode: CaptureMode.window, format: ImageFormat.jpg),
            (args: ["--mode", "multi", "--json"], mode: CaptureMode.multi, format: ImageFormat.png),
        ]
    )
    func `Various command combinations`(args: [String], mode: CaptureMode, format: ImageFormat) throws {
        let command = try ImageCommand.parse(args)
        #expect(command.mode == mode)
        #expect(command.format == format)
    }

    @Test(
        arguments: [
            (
                args: ["--mode", "screen", "--analyze", "What is on screen?"],
                mode: CaptureMode.screen,
                prompt: "What is on screen?"
            ),
            (
                args: ["--mode", "window", "--analyze", "Describe this window"],
                mode: CaptureMode.window,
                prompt: "Describe this window"
            ),
            (
                args: ["--mode", "multi", "--analyze", "Compare windows"],
                mode: CaptureMode.multi,
                prompt: "Compare windows"
            ),
            (
                args: ["--mode", "frontmost", "--analyze", "What app is this?"],
                mode: CaptureMode.frontmost,
                prompt: "What app is this?"
            ),
        ]
    )
    func `Analyze option with different modes`(args: [String], mode: CaptureMode, prompt: String) throws {
        let command = try ImageCommand.parse(args)
        #expect(command.mode == mode)
        #expect(command.analyze == prompt)
    }

    @Test(
        arguments: [
            ["--mode", "invalid"],
            ["--format", "bmp"],
            ["--capture-focus", "neither"],
            ["--screen-index", "abc"],
        ]
    )
    func `Invalid arguments throw errors`(args: [String]) {
        #expect(throws: (any Error).self) {
            try CLIOutputCapture.suppressStderr {
                _ = try ImageCommand.parse(args)
            }
        }
    }

    // MARK: - Model Tests

    @Test(.tags(.fast))
    func `SavedFile model creation`() {
        let savedFile = SavedFile(
            path: "/tmp/screenshot.png",
            item_label: "Screen 1",
            window_title: nil,
            window_id: nil,
            window_index: nil,
            mime_type: "image/png"
        )

        #expect(savedFile.path == "/tmp/screenshot.png")
        #expect(savedFile.item_label == "Screen 1")
        #expect(savedFile.mime_type == "image/png")
    }

    // MARK: - Enum Raw Value Tests

    @Test(.tags(.fast))
    func `CaptureMode raw values`() {
        #expect(CaptureMode.screen.rawValue == "screen")
        #expect(CaptureMode.window.rawValue == "window")
        #expect(CaptureMode.multi.rawValue == "multi")
    }

    @Test(.tags(.fast))
    func `ImageFormat raw values`() {
        #expect(ImageFormat.png.rawValue == "png")
        #expect(ImageFormat.jpg.rawValue == "jpg")
    }

    @Test(.tags(.fast))
    func `CaptureFocus raw values`() {
        #expect(CaptureFocus.background.rawValue == "background")
        #expect(CaptureFocus.foreground.rawValue == "foreground")
    }

    // MARK: - Mode Determination & Logic Tests

    @Test(.tags(.fast))
    func `Mode determination logic`() throws {
        // No mode, no app -> should default to screen
        let screenCommand = try ImageCommand.parse([])
        #expect(screenCommand.mode == nil)
        #expect(screenCommand.app == nil)

        // No mode, with app -> should infer window mode in actual execution
        let windowCommand = try ImageCommand.parse(["--app", "Finder"])
        #expect(windowCommand.mode == nil)
        #expect(windowCommand.app == "Finder")

        // Explicit mode should be preserved
        let explicitCommand = try ImageCommand.parse(["--mode", "multi"])
        #expect(explicitCommand.mode == .multi)
    }

    @Test(.tags(.fast))
    func `Default values verification`() throws {
        let command = try ImageCommand.parse([])

        #expect(command.mode == nil)
        #expect(command.format == .png)
        #expect(command.path == nil)
        #expect(command.app == nil)
        #expect(command.windowTitle == nil)
        #expect(command.windowIndex == nil)
        #expect(command.screenIndex == nil)
        #expect(command.region == nil)
        #expect(command.captureFocus == .background)
        #expect(command.jsonOutput == false)
        #expect(command.analyze == nil)
    }

    @Test(
        arguments: [0, 1, 99, 9999]
    )
    func `Screen index boundary values`(index: Int) throws {
        let command = try ImageCommand.parse(["--screen-index", String(index)])
        #expect(command.screenIndex == index)
    }

    @Test(
        arguments: [0, 1, 10, 9999]
    )
    func `Window index boundary values`(index: Int) throws {
        let command = try ImageCommand.parse(["--window-index", String(index)])
        #expect(command.windowIndex == index)
    }

    @Test(.tags(.fast))
    func `Error handling for invalid combinations`() {
        // Window capture without app should fail in execution
        // This tests the parsing, execution would fail later
        do {
            let command = try ImageCommand.parse(["--mode", "window"])
            #expect(command.mode == .window)
            #expect(command.app == nil) // This would cause execution error
        } catch {
            Issue.record("Parsing should succeed even with invalid combinations")
        }
    }

    // MARK: - Window Selection Tests

    @Test(.tags(.imageCapture))
    func `Prefers the first renderable main window when overlays exist`() async throws {
        let appName = "iTerm2"
        let overlay = ServiceWindowInfo(
            windowID: 10,
            title: "Command Palette",
            bounds: CGRect(x: 0, y: 0, width: 80, height: 80),
            isMinimized: false,
            isMainWindow: false,
            windowLevel: 0,
            alpha: 1.0,
            index: 0
        )
        let terminal = ServiceWindowInfo(
            windowID: 11,
            title: "zsh — main",
            bounds: CGRect(x: 50, y: 50, width: 1280, height: 720),
            isMinimized: false,
            isMainWindow: true,
            windowLevel: 0,
            alpha: 1.0,
            index: 1
        )
        let windows = [overlay, terminal]
        let appInfo = ServiceApplicationInfo(
            processIdentifier: 4242,
            bundleIdentifier: "com.googlecode.iterm2",
            name: appName,
            windowCount: windows.count
        )
        let captureResult = Self.makeCaptureResult(app: appInfo, window: terminal)
        let captureService = StubScreenCaptureService(permissionGranted: true)
        var recordedWindowID: CGWindowID?
        captureService.captureWindowByIdHandler = { windowID, _ in
            recordedWindowID = windowID
            return captureResult
        }

        let applications = StubApplicationService(applications: [appInfo], windowsByApp: [appName: windows])
        let windowService = StubWindowService(windowsByApp: [appName: windows])
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            windows: windowService,
            screenCapture: captureService
        )

        let outputPath = Self.makeTempCapturePath("iterm.png")
        var command = try ImageCommand.parse(["--app", appName, "--path", outputPath])
        command.captureFocus = .background

        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: services
        )

        try await command.run(using: runtime)
        let windowID = try #require(recordedWindowID)
        #expect(windowID == CGWindowID(terminal.windowID))
        try? FileManager.default.removeItem(atPath: outputPath)
    }

    @Test(.tags(.imageCapture))
    func `Prefers titled app windows over untitled helper windows`() async throws {
        let appName = "Google Chrome"
        let helper = ServiceWindowInfo(
            windowID: 17514,
            title: "",
            bounds: CGRect(x: 40, y: 40, width: 1200, height: 900),
            isMinimized: false,
            isMainWindow: true,
            windowLevel: 0,
            alpha: 1.0,
            index: 0
        )
        let browser = ServiceWindowInfo(
            windowID: 17513,
            title: "Craig Lyons | LinkedIn",
            bounds: CGRect(x: 50, y: 50, width: 1200, height: 900),
            isMinimized: false,
            isMainWindow: false,
            windowLevel: 0,
            alpha: 1.0,
            index: 1
        )
        let windows = [helper, browser]
        let appInfo = ServiceApplicationInfo(
            processIdentifier: 5353,
            bundleIdentifier: "com.google.Chrome",
            name: appName,
            windowCount: windows.count
        )
        let captureResult = Self.makeCaptureResult(app: appInfo, window: browser)
        let captureService = StubScreenCaptureService(permissionGranted: true)
        var recordedWindowID: CGWindowID?
        captureService.captureWindowByIdHandler = { windowID, _ in
            recordedWindowID = windowID
            return captureResult
        }

        let applications = StubApplicationService(applications: [appInfo], windowsByApp: [appName: windows])
        let windowService = StubWindowService(windowsByApp: [appName: windows])
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            windows: windowService,
            screenCapture: captureService
        )

        let outputPath = Self.makeTempCapturePath("chrome.png")
        var command = try ImageCommand.parse(["--app", appName, "--path", outputPath])
        command.captureFocus = .background

        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: services
        )

        try await command.run(using: runtime)
        let windowID = try #require(recordedWindowID)
        #expect(windowID == CGWindowID(browser.windowID))
        try? FileManager.default.removeItem(atPath: outputPath)
    }

    @Test(.tags(.imageCapture))
    func `Honors --window-title when selecting a window`() async throws {
        let appName = "LogsApp"
        let inspector = ServiceWindowInfo(
            windowID: 20,
            title: "Inspector",
            bounds: CGRect(x: 0, y: 0, width: 640, height: 480),
            isMinimized: false,
            isMainWindow: false,
            windowLevel: 0,
            alpha: 1.0,
            index: 0
        )
        let logs = ServiceWindowInfo(
            windowID: 21,
            title: "Server Logs",
            bounds: CGRect(x: 100, y: 80, width: 1024, height: 768),
            isMinimized: false,
            isMainWindow: true,
            windowLevel: 0,
            alpha: 1.0,
            index: 11
        )
        let windows = [inspector, logs]
        let appInfo = ServiceApplicationInfo(
            processIdentifier: 5252,
            bundleIdentifier: "dev.logs.app",
            name: appName,
            windowCount: windows.count
        )

        let captureResult = Self.makeCaptureResult(app: appInfo, window: logs)
        let captureService = StubScreenCaptureService(permissionGranted: true)
        var recordedWindowID: CGWindowID?
        captureService.captureWindowByIdHandler = { windowID, _ in
            recordedWindowID = windowID
            return captureResult
        }

        let applications = StubApplicationService(applications: [appInfo], windowsByApp: [appName: windows])
        let windowService = StubWindowService(windowsByApp: [appName: windows])
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            windows: windowService,
            screenCapture: captureService
        )

        let outputPath = Self.makeTempCapturePath("logs.png")
        var command = try ImageCommand.parse([
            "--app", appName,
            "--window-title", "Logs",
            "--path", outputPath,
        ])
        command.captureFocus = .background

        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: services
        )

        try await command.run(using: runtime)
        let windowID = try #require(recordedWindowID)
        #expect(windowID == CGWindowID(logs.windowID))
        try? FileManager.default.removeItem(atPath: outputPath)
    }

    @Test(.tags(.imageCapture))
    func `Throws when --window-title does not match any window`() async throws {
        let appName = "Notes"
        let notesWindow = ServiceWindowInfo(
            windowID: 31,
            title: "All Notes",
            bounds: CGRect(x: 0, y: 0, width: 900, height: 600),
            isMinimized: false,
            isMainWindow: true,
            windowLevel: 0,
            alpha: 1.0,
            index: 0
        )
        let appInfo = ServiceApplicationInfo(
            processIdentifier: 6060,
            bundleIdentifier: "com.example.notes",
            name: appName,
            windowCount: 1
        )

        let captureService = StubScreenCaptureService(permissionGranted: true)
        let applications = StubApplicationService(applications: [appInfo], windowsByApp: [appName: [notesWindow]])
        let windowService = StubWindowService(windowsByApp: [appName: [notesWindow]])
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            windows: windowService,
            screenCapture: captureService
        )

        let result = try await InProcessCommandRunner.run(
            [
                "image",
                "--app", appName,
                "--window-title", "Nonexistent",
                "--capture-focus", "background",
                "--path", Self.makeTempCapturePath("notes.png"),
                "--json",
            ],
            services: services
        )

        #expect(result.exitStatus == 1)

        let response = try JSONDecoder().decode(
            JSONResponse.self,
            from: Data(result.combinedOutput.utf8)
        )
        #expect(response.success == false)
        #expect(response.error?.code == ErrorCode.WINDOW_NOT_FOUND.rawValue)
    }

    @Test(.tags(.imageCapture))
    func `Defaults to 1x logical scale`() async throws {
        let screens = [Self.makeScreenInfo(scale: 2.0)]
        let captureResult = Self.makeScreenCaptureResult(size: CGSize(width: 1200, height: 800), scale: 1.0)
        let captureService = StubScreenCaptureService(permissionGranted: true)
        var recordedScale: CaptureScalePreference?
        captureService.captureScreenHandler = { _, scale in
            recordedScale = scale
            return captureResult
        }

        let services = TestServicesFactory.makePeekabooServices(
            screens: screens,
            screenCapture: captureService
        )

        var command = try ImageCommand.parse([
            "--mode", "screen",
            "--path", Self.makeTempCapturePath("logical.png"),
            "--json",
        ])

        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: services
        )

        try await command.run(using: runtime)

        #expect(recordedScale == .logical1x)
    }

    @Test(.tags(.imageCapture))
    func `Retina flag opts into native scale`() async throws {
        let screens = [Self.makeScreenInfo(scale: 2.0)]
        let captureResult = Self.makeScreenCaptureResult(size: CGSize(width: 2400, height: 1600), scale: 2.0)
        let captureService = StubScreenCaptureService(permissionGranted: true)
        var recordedScale: CaptureScalePreference?
        captureService.captureScreenHandler = { _, scale in
            recordedScale = scale
            return captureResult
        }

        let services = TestServicesFactory.makePeekabooServices(
            screens: screens,
            screenCapture: captureService
        )

        var command = try ImageCommand.parse([
            "--mode", "screen",
            "--retina",
            "--path", Self.makeTempCapturePath("retina.png"),
            "--json",
        ])

        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: services
        )

        try await command.run(using: runtime)

        #expect(recordedScale == .native)
    }

    @Test(.tags(.imageCapture))
    func `Retina flag applies to window ID captures`() async throws {
        let window = ServiceWindowInfo(
            windowID: 120_099,
            title: "Zephyr Agency",
            bounds: CGRect(x: 50, y: 50, width: 1460, height: 945)
        )
        let app = ServiceApplicationInfo(
            processIdentifier: 7373,
            bundleIdentifier: "app.zephyr.agency",
            name: "Zephyr Agency",
            windowCount: 1
        )
        let captureService = StubScreenCaptureService(permissionGranted: true)
        var recordedWindowID: CGWindowID?
        var recordedScale: CaptureScalePreference?
        captureService.captureWindowByIdHandler = { windowID, scale in
            recordedWindowID = windowID
            recordedScale = scale
            return Self.makeCaptureResult(app: app, window: window)
        }

        let services = TestServicesFactory.makePeekabooServices(screenCapture: captureService)
        let path = Self.makeTempCapturePath("window-id-retina.png")
        var command = try ImageCommand.parse([
            "--window-id", "\(window.windowID)",
            "--retina",
            "--path", path,
            "--json",
        ])

        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: services
        )

        try await command.run(using: runtime)

        #expect(recordedWindowID == CGWindowID(window.windowID))
        #expect(recordedScale == .native)
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test(.tags(.imageCapture))
    func `App capture skips offscreen toolbar helpers`() async throws {
        let appName = "Zephyr Agency"
        let toolbar = ServiceWindowInfo(
            windowID: 140_686,
            title: "",
            bounds: CGRect(x: -10000, y: -10000, width: 2560, height: 30),
            index: 0
        )
        let mainWindow = ServiceWindowInfo(
            windowID: 120_099,
            title: appName,
            bounds: CGRect(x: 50, y: 50, width: 1460, height: 945),
            isMainWindow: true,
            index: 1
        )
        let windows = [toolbar, mainWindow]
        let appInfo = ServiceApplicationInfo(
            processIdentifier: 7373,
            bundleIdentifier: "app.zephyr.agency",
            name: appName,
            windowCount: windows.count
        )

        let captureService = StubScreenCaptureService(permissionGranted: true)
        var recordedWindowID: CGWindowID?
        captureService.captureWindowByIdHandler = { windowID, _ in
            recordedWindowID = windowID
            return Self.makeCaptureResult(app: appInfo, window: mainWindow)
        }

        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [appInfo], windowsByApp: [appName: windows]),
            windows: StubWindowService(windowsByApp: [appName: windows]),
            screenCapture: captureService
        )

        let path = Self.makeTempCapturePath("zephyr.png")
        var command = try ImageCommand.parse(["--app", appName, "--path", path])
        command.captureFocus = .background

        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: services
        )

        try await command.run(using: runtime)

        #expect(recordedWindowID == CGWindowID(mainWindow.windowID))
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test(.tags(.imageCapture))
    func `App capture auto focus skips activation when visible window exists`() async throws {
        let appName = "SwiftPM GUI"
        let mainWindow = ServiceWindowInfo(
            windowID: 13665,
            title: "SwiftPM GUI",
            bounds: CGRect(x: 200, y: 120, width: 450, height: 732),
            isMainWindow: true,
            index: 0
        )
        let appInfo = ServiceApplicationInfo(
            processIdentifier: 6767,
            bundleIdentifier: nil,
            name: appName,
            windowCount: 1
        )

        let captureService = StubScreenCaptureService(permissionGranted: true)
        var recordedWindowID: CGWindowID?
        captureService.captureWindowByIdHandler = { windowID, _ in
            recordedWindowID = windowID
            return Self.makeCaptureResult(app: appInfo, window: mainWindow)
        }

        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [appInfo], windowsByApp: [appName: [mainWindow]]),
            windows: StubWindowService(windowsByApp: [appName: [mainWindow]]),
            screenCapture: captureService
        )

        let path = Self.makeTempCapturePath("swiftpm-gui.png")
        var command = try ImageCommand.parse(["--app", appName, "--path", path])

        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: services
        )

        try await command.run(using: runtime)

        #expect(recordedWindowID == CGWindowID(mainWindow.windowID))
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test(.tags(.imageCapture))
    func `Skips windows marked non-shareable`() async throws {
        let appName = "Console"
        let hidden = ServiceWindowInfo(
            windowID: 90,
            title: "Console Overlay",
            bounds: CGRect(x: 0, y: 0, width: 400, height: 200),
            index: 0,
            sharingState: .some(.none)
        )
        let visible = ServiceWindowInfo(
            windowID: 91,
            title: "Logs",
            bounds: CGRect(x: 40, y: 40, width: 1400, height: 900),
            index: 1,
            sharingState: .readWrite
        )

        let appInfo = ServiceApplicationInfo(
            processIdentifier: 7070,
            bundleIdentifier: "dev.console",
            name: appName,
            windowCount: 2
        )

        let captureResult = Self.makeCaptureResult(app: appInfo, window: visible)
        let captureService = StubScreenCaptureService(permissionGranted: true)
        var recordedWindowID: CGWindowID?
        captureService.captureWindowByIdHandler = { windowID, _ in
            recordedWindowID = windowID
            return captureResult
        }

        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [appInfo], windowsByApp: [appName: [hidden, visible]]),
            windows: StubWindowService(windowsByApp: [appName: [hidden, visible]]),
            screenCapture: captureService
        )

        let path = Self.makeTempCapturePath("console.png")
        var command = try ImageCommand.parse(["--app", appName, "--path", path])
        command.captureFocus = .background

        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: services
        )

        try await command.run(using: runtime)
        let windowID = try #require(recordedWindowID)
        #expect(windowID == CGWindowID(visible.windowID))
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test(.tags(.imageCapture))
    func `Errors when only hidden windows remain`() async throws {
        let appName = "OverlayApp"
        let hidden = ServiceWindowInfo(
            windowID: 101,
            title: "Overlay",
            bounds: CGRect(x: 0, y: 0, width: 500, height: 300),
            sharingState: .some(.none)
        )
        let appInfo = ServiceApplicationInfo(
            processIdentifier: 9090,
            bundleIdentifier: "dev.overlay",
            name: appName,
            windowCount: 1
        )

        let captureService = StubScreenCaptureService(permissionGranted: true)
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [appInfo], windowsByApp: [appName: [hidden]]),
            windows: StubWindowService(windowsByApp: [appName: [hidden]]),
            screenCapture: captureService
        )

        let result = try await InProcessCommandRunner.run(
            [
                "image",
                "--app", appName,
                "--capture-focus", "background",
                "--path", Self.makeTempCapturePath("overlay.png"),
                "--json",
            ],
            services: services
        )

        #expect(result.exitStatus == 1)

        let response = try JSONDecoder().decode(
            JSONResponse.self,
            from: Data(result.combinedOutput.utf8)
        )
        #expect(response.success == false)
        #expect(response.error?.code == ErrorCode.WINDOW_NOT_FOUND.rawValue)
    }
}
#endif
