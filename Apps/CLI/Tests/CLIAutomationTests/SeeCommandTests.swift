import CoreGraphics
import Foundation
import PeekabooAutomation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.serialized, .tags(.safe))
struct SeeCommandTests {
    @Test
    func `See command parses correctly with minimal arguments`() throws {
        let command = try SeeCommand.parse(["--path", "/tmp/test.png"])
        #expect(command.path == "/tmp/test.png")
        #expect(command.app == nil)
        #expect(command.mode == nil) // No longer has default value
        #expect(command.windowTitle == nil)
        #expect(command.annotate == false)
        #expect(command.jsonOutput == false)
    }

    @Test
    func `See command parses all arguments correctly`() throws {
        let command = try SeeCommand.parse([
            "--app", "Safari",
            "--path", "/tmp/screenshot.png",
            "--annotate",
            "--json",
        ])
        #expect(command.app == "Safari")
        #expect(command.path == "/tmp/screenshot.png")
        #expect(command.annotate == true)
        #expect(command.jsonOutput == true)
    }

    @Test(arguments: [
        "screen",
        "window",
        "frontmost",
    ])
    func `See command handles different capture modes`(modeString: String) throws {
        let command = try SeeCommand.parse(["--mode", modeString])
        #expect(command.mode?.rawValue == modeString)
    }

    @Test
    func `See command auto-infers window mode when app is specified`() throws {
        let command = try SeeCommand.parse(["--app", "Safari"])
        #expect(command.app == "Safari")
        #expect(command.mode == nil) // Mode not explicitly set
    }

    @Test
    func `See command parses screen-index parameter`() throws {
        let command = try SeeCommand.parse(["--mode", "screen", "--screen-index", "1"])
        #expect(command.mode == .screen)
        #expect(command.screenIndex == 1)
    }

    @Test
    func `See command screen-index only works with screen mode`() throws {
        // Should parse without error even if not in screen mode
        let command = try SeeCommand.parse(["--mode", "window", "--screen-index", "0"])
        #expect(command.screenIndex == 0)
        // The validation happens at runtime, not parse time
    }

    @Test
    func `See command handles multi-screen capture defaults`() throws {
        let command = try SeeCommand.parse(["--mode", "screen"])
        #expect(command.screenIndex == nil) // No index means capture all screens
    }

    @Test
    func `See command auto-infers window mode when window title is specified`() throws {
        let command = try SeeCommand.parse(["--window-title", "Document"])
        #expect(command.windowTitle == "Document")
        #expect(command.mode == nil) // Mode not explicitly set
    }

    @Test
    func `See result structure contains all required fields`() {
        let element = UIElementSummary(
            id: "B1",
            role: "button",
            title: "Save",
            label: nil,
            description: nil,
            role_description: nil,
            help: nil,
            identifier: nil,
            bounds: UIElementBounds(CGRect(x: 0, y: 0, width: 100, height: 30)),
            is_actionable: true,
            keyboard_shortcut: nil
        )

        let result = SeeResult(
            snapshot_id: "test-123",
            screenshot_raw: "/tmp/screenshot.png",
            screenshot_annotated: "/tmp/screenshot_annotated.png",
            ui_map: "/tmp/snapshot.json",
            application_name: "TestApp",
            window_title: "Test Window",
            is_dialog: false,
            element_count: 10,
            interactable_count: 5,
            capture_mode: "frontmost",
            analysis: nil,
            execution_time: 1.5,
            ui_elements: [element],
            menu_bar: nil
        )

        #expect(result.snapshot_id == "test-123")
        #expect(result.screenshot_raw == "/tmp/screenshot.png")
        #expect(result.screenshot_annotated == "/tmp/screenshot_annotated.png")
        #expect(result.ui_map == "/tmp/snapshot.json")
        #expect(result.ui_elements.count == 1)
        #expect(result.ui_elements.first?.id == "B1")
        #expect(result.application_name == "TestApp")
        #expect(result.window_title == "Test Window")
    }

    @Test
    func `See command validates path parameter`() {
        // Test that command can be created with valid path
        #expect(throws: Never.self) {
            _ = try SeeCommand.parse(["--path", "/tmp/valid.png"])
        }

        // Test default path generation when not provided
        #expect(throws: Never.self) {
            let command = try SeeCommand.parse([])
            #expect(command.path == nil)
        }
    }

    @Test
    func `See command with analyze option`() throws {
        let command = try SeeCommand.parse([
            "--analyze", "What is shown in this screenshot?",
        ])
        #expect(command.analyze == "What is shown in this screenshot?")
    }

    @Test
    func `See command with window title`() throws {
        let command = try SeeCommand.parse([
            "--app", "Safari",
            "--window-title", "GitHub",
        ])
        #expect(command.app == "Safari")
        #expect(command.windowTitle == "GitHub")
    }
}

@Suite(.serialized, .tags(.fast))
struct SeeCommandRuntimeTests {
    @Test
    @MainActor
    func `Remote See publishes a host-certified observation without a caller barrier`() async throws {
        try await self.withTempConfigEnv { tempDir in
            let fixture = Self.makeSeeCommandRuntimeFixture()
            let automation = StubAutomationService()
            automation.detectElementsHandler = { _, snapshotID, _ in
                let metadata = fixture.detectionResult.metadata
                return try ElementDetectionResult(
                    snapshotId: #require(snapshotID),
                    screenshotPath: fixture.detectionResult.screenshotPath,
                    elements: fixture.detectionResult.elements,
                    metadata: DetectionMetadata(
                        detectionTime: metadata.detectionTime,
                        elementCount: metadata.elementCount,
                        method: metadata.method,
                        warnings: metadata.warnings,
                        windowContext: metadata.windowContext,
                        isDialog: metadata.isDialog,
                        truncationInfo: metadata.truncationInfo,
                        desktopMutationCompletedAt: Date(),
                        desktopMutationPreservationAllowed: true
                    )
                )
            }

            let watermarkStore = DesktopMutationWatermarkStore(directoryURL: tempDir)
            let snapshots = InMemorySnapshotManager(desktopMutationWatermarkStore: watermarkStore)
            let windowsByApp = [fixture.applicationInfo.name: [fixture.windowInfo]]
            let services = TestServicesFactory.makePeekabooServices(
                applications: StubApplicationService(
                    applications: [fixture.applicationInfo],
                    windowsByApp: windowsByApp
                ),
                windows: StubWindowService(windowsByApp: windowsByApp),
                snapshots: snapshots,
                automation: automation,
                screenCapture: fixture.screenCapture
            )
            let outputURL = tempDir.appendingPathComponent("remote-see.png")
            var command = try SeeCommand.parse([
                "--mode", "frontmost",
                "--no-web-focus",
                "--path", outputURL.path,
                "--json",
            ])
            let runtime = CommandRuntime(
                configuration: .init(
                    verbose: false,
                    jsonOutput: true,
                    logLevel: nil,
                    captureEnginePreference: nil,
                    inputStrategy: nil
                ),
                services: services,
                selectedRemoteSocketPath: "/tmp/selected.sock",
                interactionMutationTracker: InteractionMutationTracker(
                    desktopMutationWatermarkStore: watermarkStore
                )
            )

            try await command.run(using: runtime)

            #expect(await snapshots.getMostRecentSnapshot() != nil)
            #expect(!runtime.interactionMutationTracker.hasPendingDurableMutation)
        }
    }

    @Test
    func `See without web focus publishes only a complete snapshot`() async throws {
        try await self.withTempConfigEnv { _ in
            let fixture = Self.makeSeeCommandRuntimeFixture()
            let automation = StubAutomationService()
            automation.nextDetectionResult = fixture.detectionResult

            let (context, outputURL) = Self.makeSeeCommandRuntimeContext(
                automation: automation,
                screenCapture: fixture.screenCapture,
                applicationInfo: fixture.applicationInfo,
                windowInfo: fixture.windowInfo
            )
            defer { try? FileManager.default.removeItem(at: outputURL) }

            let result = try await InProcessCommandRunner.run(
                [
                    "see",
                    "--mode", "frontmost",
                    "--no-web-focus",
                    "--path", outputURL.path,
                ],
                services: context.services
            )

            #expect(result.exitStatus == 0)

            let storedScreenshots = context.snapshots.storedScreenshots.values.flatMap(\.self)
            #expect(storedScreenshots.count == 1)
            #expect(storedScreenshots.first?.path == outputURL.path)
            #expect(storedScreenshots.first?.applicationName == fixture.applicationInfo.name)
            #expect(storedScreenshots.first?.windowTitle == fixture.windowInfo.title)
            #expect(!context.snapshots.exposedPendingSnapshotDuringWrite)
            let storedSnapshotID = try #require(context.snapshots.storedScreenshots.keys.first)
            #expect(await context.snapshots.getMostRecentSnapshot() == storedSnapshotID)
            #expect(automation.detectElementsCalls.first?.snapshotId == storedSnapshotID)
        }
    }

    @Test
    func `JSON See without path keeps screenshot private to snapshot storage`() async throws {
        try await self.withTempConfigEnv { _ in
            let fixture = Self.makeSeeCommandRuntimeFixture()
            let automation = StubAutomationService()
            automation.nextDetectionResult = fixture.detectionResult

            let (context, _) = Self.makeSeeCommandRuntimeContext(
                automation: automation,
                screenCapture: fixture.screenCapture,
                applicationInfo: fixture.applicationInfo,
                windowInfo: fixture.windowInfo
            )
            context.snapshots.copiesScreenshotArtifactsIntoStorage = true

            let result = try await InProcessCommandRunner.run(
                [
                    "see",
                    "--mode", "frontmost",
                    "--no-web-focus",
                    "--json",
                ],
                services: context.services
            )

            let data = try #require(result.stdout.data(using: .utf8))
            let response = try JSONDecoder().decode(
                CodableJSONResponse<SeeResult>.self,
                from: data
            )
            let storedScreenshot = try #require(
                context.snapshots.storedScreenshots.values.flatMap(\.self).first
            )

            #expect(result.exitStatus == 0)
            #expect(response.data.screenshot_raw.isEmpty)
            #expect(response.data.screenshot_annotated.isEmpty)
            #expect(storedScreenshot.path.hasPrefix(FileManager.default.temporaryDirectory.path))
            #expect(!FileManager.default.fileExists(atPath: storedScreenshot.path))
        }
    }

    @Test
    func `JSON See retains temporary screenshot for borrowing snapshot backend`() async throws {
        try await self.withTempConfigEnv { _ in
            let fixture = Self.makeSeeCommandRuntimeFixture()
            let automation = StubAutomationService()
            automation.nextDetectionResult = fixture.detectionResult

            let (context, _) = Self.makeSeeCommandRuntimeContext(
                automation: automation,
                screenCapture: fixture.screenCapture,
                applicationInfo: fixture.applicationInfo,
                windowInfo: fixture.windowInfo
            )

            let result = try await InProcessCommandRunner.run(
                [
                    "see",
                    "--mode", "frontmost",
                    "--no-web-focus",
                    "--json",
                ],
                services: context.services
            )

            let data = try #require(result.stdout.data(using: .utf8))
            let response = try JSONDecoder().decode(
                CodableJSONResponse<SeeResult>.self,
                from: data
            )
            let storedScreenshot = try #require(
                context.snapshots.storedScreenshots.values.flatMap(\.self).first
            )
            defer {
                try? FileManager.default.removeItem(
                    at: URL(fileURLWithPath: storedScreenshot.path).deletingLastPathComponent()
                )
            }

            #expect(result.exitStatus == 0)
            #expect(response.data.screenshot_raw.isEmpty)
            #expect(FileManager.default.fileExists(atPath: storedScreenshot.path))
        }
    }

    @Test
    func `See suppresses success output when snapshot publication fails`() async throws {
        try await self.withTempConfigEnv { _ in
            let fixture = Self.makeSeeCommandRuntimeFixture()
            let automation = StubAutomationService()
            automation.nextDetectionResult = fixture.detectionResult

            let (context, outputURL) = Self.makeSeeCommandRuntimeContext(
                automation: automation,
                screenCapture: fixture.screenCapture,
                applicationInfo: fixture.applicationInfo,
                windowInfo: fixture.windowInfo
            )
            context.snapshots.invalidationError = PeekabooError.operationError(
                message: "invalidation unavailable"
            )
            defer { try? FileManager.default.removeItem(at: outputURL) }

            let result = try await InProcessCommandRunner.run(
                [
                    "see",
                    "--mode", "frontmost",
                    "--no-web-focus",
                    "--path", outputURL.path,
                    "--json",
                ],
                services: context.services
            )

            #expect(result.exitStatus == 1)
            #expect(!result.combinedOutput.contains("\"snapshot_id\""))
            #expect(context.snapshots.invalidationCutoffs.count >= 2)
            #expect(try await context.snapshots.listSnapshots().isEmpty)
        }
    }

    @Test
    func `See snapshot reservation remains inside the overall timeout`() async throws {
        try await self.withTempConfigEnv { _ in
            let fixture = Self.makeSeeCommandRuntimeFixture()
            let automation = StubAutomationService()
            automation.nextDetectionResult = fixture.detectionResult

            let (context, outputURL) = Self.makeSeeCommandRuntimeContext(
                automation: automation,
                screenCapture: fixture.screenCapture,
                applicationInfo: fixture.applicationInfo,
                windowInfo: fixture.windowInfo
            )
            context.snapshots.snapshotCreationDelay = .seconds(4)
            defer { try? FileManager.default.removeItem(at: outputURL) }

            let startedAt = ContinuousClock.now
            let result = try await InProcessCommandRunner.run(
                [
                    "see",
                    "--mode", "frontmost",
                    "--no-web-focus",
                    "--timeout-seconds", "1",
                    "--path", outputURL.path,
                    "--json",
                ],
                services: context.services
            )
            let elapsed = startedAt.duration(to: .now)

            #expect(result.exitStatus == 1)
            #expect(elapsed < .seconds(2.5))
            #expect(!result.combinedOutput.contains("\"snapshot_id\""))
            #expect(try await context.snapshots.listSnapshots().isEmpty)
        }
    }

    @Test
    func `See publication remains inside the overall timeout`() async throws {
        try await self.withTempConfigEnv { _ in
            let fixture = Self.makeSeeCommandRuntimeFixture()
            let automation = StubAutomationService()
            automation.nextDetectionResult = fixture.detectionResult

            let (context, outputURL) = Self.makeSeeCommandRuntimeContext(
                automation: automation,
                screenCapture: fixture.screenCapture,
                applicationInfo: fixture.applicationInfo,
                windowInfo: fixture.windowInfo
            )
            context.snapshots.preservingInvalidationDelay = .seconds(4)
            defer { try? FileManager.default.removeItem(at: outputURL) }

            let startedAt = ContinuousClock.now
            let result = try await InProcessCommandRunner.run(
                [
                    "see",
                    "--mode", "frontmost",
                    "--no-web-focus",
                    "--timeout-seconds", "1",
                    "--path", outputURL.path,
                    "--json",
                ],
                services: context.services
            )
            let elapsed = startedAt.duration(to: .now)

            #expect(result.exitStatus == 1)
            #expect(elapsed < .seconds(2.5))
            #expect(!result.combinedOutput.contains("\"snapshot_id\""))
            #expect(try await context.snapshots.listSnapshots().isEmpty)
        }
    }

    @Test
    func `Timed out See keeps late snapshot writes hidden`() async throws {
        try await self.withTempConfigEnv { _ in
            let fixture = Self.makeSeeCommandRuntimeFixture()
            let automation = StubAutomationService()
            let (context, outputURL) = Self.makeSeeCommandRuntimeContext(
                automation: automation,
                screenCapture: fixture.screenCapture,
                applicationInfo: fixture.applicationInfo,
                windowInfo: fixture.windowInfo
            )
            defer { try? FileManager.default.removeItem(at: outputURL) }
            var lateWriteTask: Task<Void, Never>?
            var lateWriteSucceeded = false

            automation.detectElementsHandler = { _, snapshotID, _ in
                let snapshotID = try #require(snapshotID)
                let lateResult = ElementDetectionResult(
                    snapshotId: snapshotID,
                    screenshotPath: outputURL.path,
                    elements: fixture.detectionResult.elements,
                    metadata: fixture.detectionResult.metadata
                )
                let task = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.2))
                    do {
                        try await context.snapshots.storeDetectionResult(
                            snapshotId: snapshotID,
                            result: lateResult
                        )
                        lateWriteSucceeded = true
                    } catch {
                        Issue.record("Late snapshot write failed: \(error)")
                    }
                }
                lateWriteTask = task
                await task.value
                throw TestStubError.unimplemented(#function)
            }

            let result = try await InProcessCommandRunner.run(
                [
                    "see",
                    "--mode", "frontmost",
                    "--no-web-focus",
                    "--timeout-seconds", "1",
                    "--path", outputURL.path,
                ],
                services: context.services
            )

            #expect(result.exitStatus == 1)
            guard let task = lateWriteTask else {
                Issue.record("See never started detection: \(result.combinedOutput)")
                return
            }
            await task.value
            #expect(lateWriteSucceeded)
            #expect(await context.snapshots.getMostRecentSnapshot() == nil)
            #expect(try await context.snapshots.listSnapshots().isEmpty)
        }
    }

    @Test
    func `Bridge transport timeout keeps late See writes hidden`() async throws {
        try await self.withTempConfigEnv { _ in
            let fixture = Self.makeSeeCommandRuntimeFixture()
            let automation = StubAutomationService()
            let (context, outputURL) = Self.makeSeeCommandRuntimeContext(
                automation: automation,
                screenCapture: fixture.screenCapture,
                applicationInfo: fixture.applicationInfo,
                windowInfo: fixture.windowInfo
            )
            defer { try? FileManager.default.removeItem(at: outputURL) }
            var lateWriteTask: Task<Void, Never>?

            automation.detectElementsHandler = { _, snapshotID, _ in
                let snapshotID = try #require(snapshotID)
                let lateResult = ElementDetectionResult(
                    snapshotId: snapshotID,
                    screenshotPath: outputURL.path,
                    elements: fixture.detectionResult.elements,
                    metadata: fixture.detectionResult.metadata
                )
                let task = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    try? await context.snapshots.storeDetectionResult(
                        snapshotId: snapshotID,
                        result: lateResult
                    )
                }
                lateWriteTask = task
                throw POSIXError(.ETIMEDOUT)
            }

            let result = try await InProcessCommandRunner.run(
                [
                    "see",
                    "--mode", "frontmost",
                    "--no-web-focus",
                    "--path", outputURL.path,
                ],
                services: context.services
            )

            #expect(result.exitStatus == 1)
            let task = try #require(lateWriteTask)
            await task.value
            #expect(!context.snapshots.detectionResults.isEmpty)
            #expect(await context.snapshots.getMostRecentSnapshot() == nil)
            #expect(try await context.snapshots.listSnapshots().isEmpty)
        }
    }

    @Test
    func `Timed out See drops a late successful completion`() async throws {
        try await self.withTempConfigEnv { _ in
            let fixture = Self.makeSeeCommandRuntimeFixture()
            let automation = StubAutomationService()
            let (context, outputURL) = Self.makeSeeCommandRuntimeContext(
                automation: automation,
                screenCapture: fixture.screenCapture,
                applicationInfo: fixture.applicationInfo,
                windowInfo: fixture.windowInfo
            )
            defer {
                CLIInstrumentation.LoggerControl.clearDebugLogs()
                try? FileManager.default.removeItem(at: outputURL)
            }
            CLIInstrumentation.LoggerControl.clearDebugLogs()
            var lateDetectionTask: Task<ElementDetectionResult, Never>?

            automation.detectElementsHandler = { _, snapshotID, _ in
                let snapshotID = try #require(snapshotID)
                let lateResult = ElementDetectionResult(
                    snapshotId: snapshotID,
                    screenshotPath: outputURL.path,
                    elements: fixture.detectionResult.elements,
                    metadata: fixture.detectionResult.metadata
                )
                let task = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.2))
                    return lateResult
                }
                lateDetectionTask = task
                return await task.value
            }

            let result = try await InProcessCommandRunner.run(
                [
                    "see",
                    "--mode", "frontmost",
                    "--no-web-focus",
                    "--timeout-seconds", "1",
                    "--path", outputURL.path,
                    "--json",
                ],
                services: context.services
            )

            #expect(result.exitStatus == 1)
            guard let task = lateDetectionTask else {
                Issue.record("See never started detection: \(result.combinedOutput)")
                return
            }
            _ = await task.value
            for _ in 0..<100 where context.snapshots.detectionResults.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
            try await Task.sleep(for: .milliseconds(50))
            CLIInstrumentation.LoggerControl.flush()
            let logs = CLIInstrumentation.LoggerControl.debugLogs()
            #expect(!logs.contains { line in
                line.contains("Operation completed") &&
                    line.contains("operation=see_command") &&
                    line.contains("success=true")
            })
            #expect(!context.snapshots.detectionResults.isEmpty)
            #expect(await context.snapshots.getMostRecentSnapshot() == nil)
            #expect(try await context.snapshots.listSnapshots().isEmpty)
        }
    }

    @Test
    func `See command JSON includes accessibility metadata fields`() async throws {
        let fixture = Self.makeSeeCommandRuntimeFixture()
        let automation = StubAutomationService()

        let enrichedElement = DetectedElement(
            id: "B42",
            type: .button,
            label: nil,
            value: nil,
            bounds: CGRect(x: 50, y: 60, width: 34, height: 34),
            isEnabled: true,
            isSelected: nil,
            attributes: [
                "description": "Wingman Grindr Session Helper",
                "roleDescription": "Pop Up Button",
                "help": "Pinned extension button",
                "identifier": "wingman-session-helper"
            ]
        )

        let detectionResult = ElementDetectionResult(
            snapshotId: fixture.snapshotId,
            screenshotPath: fixture.detectionResult.screenshotPath,
            elements: DetectedElements(buttons: [enrichedElement]),
            metadata: fixture.detectionResult.metadata
        )
        automation.nextDetectionResult = detectionResult

        try await self.withTempConfigEnv { _ in
            let (context, outputURL) = Self.makeSeeCommandRuntimeContext(
                automation: automation,
                screenCapture: fixture.screenCapture,
                applicationInfo: fixture.applicationInfo,
                windowInfo: fixture.windowInfo
            )
            defer { try? FileManager.default.removeItem(at: outputURL) }

            let result = try await InProcessCommandRunner.run(
                [
                    "see",
                    "--mode", "frontmost",
                    "--path", outputURL.path,
                    "--json",
                ],
                services: context.services
            )

            let data = try #require(result.stdout.data(using: .utf8))
            let response = try JSONDecoder().decode(
                CodableJSONResponse<SeeResult>.self,
                from: data
            )
            let element = try #require(response.data.ui_elements.first)

            #expect(response.success == true)
            #expect(element.description == "Wingman Grindr Session Helper")
            #expect(element.role_description == "Pop Up Button")
            #expect(element.help == "Pinned extension button")
            #expect(element.identifier == "wingman-session-helper")
        }
    }

    @Test
    func `See screen JSON does not include human screen summary`() async throws {
        let fixture = Self.makeSeeCommandRuntimeFixture()
        let automation = StubAutomationService()
        automation.nextDetectionResult = fixture.detectionResult

        let screen = ScreenInfo(
            index: 0,
            name: "Primary",
            frame: CGRect(x: 0, y: 0, width: 320, height: 240),
            visibleFrame: CGRect(x: 0, y: 0, width: 320, height: 240),
            isPrimary: true,
            scaleFactor: 1,
            displayID: 1
        )
        let screenCapture = StubScreenCaptureService(permissionGranted: true)
        screenCapture.captureScreenHandler = { _, _ in
            CaptureResult(
                imageData: Data(repeating: 0xCD, count: 16),
                metadata: CaptureMetadata(
                    size: screen.frame.size,
                    mode: .screen,
                    displayInfo: DisplayInfo(
                        index: screen.index,
                        name: screen.name,
                        bounds: screen.frame,
                        scaleFactor: screen.scaleFactor
                    )
                )
            )
        }

        try await self.withTempConfigEnv { _ in
            let context = TestServicesFactory.makeAutomationTestContext(
                automation: automation,
                screens: [screen],
                screenCapture: screenCapture
            )
            let outputURL = FileManager.default
                .temporaryDirectory
                .appendingPathComponent("peekaboo-see-screen-json.png")
            defer { try? FileManager.default.removeItem(at: outputURL) }

            let result = try await InProcessCommandRunner.run(
                [
                    "see",
                    "--mode", "screen",
                    "--path", outputURL.path,
                    "--json",
                ],
                services: context.services
            )

            let data = try #require(result.stdout.data(using: .utf8))
            let response = try JSONDecoder().decode(
                CodableJSONResponse<SeeResult>.self,
                from: data
            )

            #expect(response.success == true)
            #expect(!result.stdout.contains("Captured 1 screen"))
            #expect(!result.stdout.contains("[scrn]"))
        }
    }

    private func withTempConfigEnv<T>(
        _ body: @escaping (URL) async throws -> T
    ) async throws -> T {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        setenv("PEEKABOO_CONFIG_DIR", tempDir.path, 1)
        setenv("PEEKABOO_CONFIG_NONINTERACTIVE", "1", 1)
        setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", "1", 1)
        #if DEBUG
        ConfigurationManager.shared.resetForTesting()
        #endif

        defer {
            unsetenv("PEEKABOO_CONFIG_DIR")
            unsetenv("PEEKABOO_CONFIG_NONINTERACTIVE")
            unsetenv("PEEKABOO_CONFIG_DISABLE_MIGRATION")
            #if DEBUG
            ConfigurationManager.shared.resetForTesting()
            #endif
            try? FileManager.default.removeItem(at: tempDir)
        }

        return try await body(tempDir)
    }
}

extension SeeCommandRuntimeTests {
    fileprivate struct RuntimeFixture {
        let snapshotId: String
        let applicationInfo: ServiceApplicationInfo
        let windowInfo: ServiceWindowInfo
        let screenCapture: StubScreenCaptureService
        let detectionResult: ElementDetectionResult
    }

    fileprivate static func makeSeeCommandRuntimeFixture() -> RuntimeFixture {
        let snapshotId = UUID().uuidString
        let windowBounds = CGRect(x: 10, y: 20, width: 800, height: 600)
        let applicationInfo = Self.makeSeeFixtureApplicationInfo()
        let windowInfo = Self.makeSeeFixtureWindowInfo(windowBounds: windowBounds)
        let captureResult = Self.makeSeeFixtureCaptureResult(
            applicationInfo: applicationInfo,
            windowInfo: windowInfo
        )
        let screenCapture = Self.makeSeeFixtureScreenCapture(captureResult: captureResult)
        let detectionResult = Self.makeSeeFixtureDetectionResult(
            snapshotId: snapshotId,
            applicationInfo: applicationInfo,
            windowInfo: windowInfo,
            windowBounds: windowBounds
        )

        return RuntimeFixture(
            snapshotId: snapshotId,
            applicationInfo: applicationInfo,
            windowInfo: windowInfo,
            screenCapture: screenCapture,
            detectionResult: detectionResult
        )
    }

    fileprivate static func makeSeeCommandRuntimeContext(
        automation: StubAutomationService,
        screenCapture: StubScreenCaptureService,
        applicationInfo: ServiceApplicationInfo? = nil,
        windowInfo: ServiceWindowInfo? = nil
    ) -> (context: TestServicesFactory.AutomationTestContext, outputURL: URL) {
        var windowsByApp: [String: [ServiceWindowInfo]] = [:]
        if let applicationInfo, let windowInfo {
            windowsByApp[applicationInfo.name] = [windowInfo]
            if let bundleIdentifier = applicationInfo.bundleIdentifier {
                windowsByApp[bundleIdentifier] = [windowInfo]
            }
        }
        let applications = applicationInfo.map { [$0] } ?? []
        let context = TestServicesFactory.makeAutomationTestContext(
            automation: automation,
            applications: StubApplicationService(applications: applications, windowsByApp: windowsByApp),
            windows: StubWindowService(windowsByApp: windowsByApp),
            screenCapture: screenCapture
        )
        let outputURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("peekaboo-see-runtime.png")
        return (context, outputURL)
    }

    fileprivate static func makeSeeFixtureApplicationInfo() -> ServiceApplicationInfo {
        ServiceApplicationInfo(
            processIdentifier: 4242,
            bundleIdentifier: "com.example.app",
            name: "ExampleApp",
            isActive: true,
            windowCount: 1
        )
    }

    fileprivate static func makeSeeFixtureWindowInfo(windowBounds: CGRect) -> ServiceWindowInfo {
        ServiceWindowInfo(
            windowID: 101,
            title: "Main Window",
            bounds: windowBounds,
            isMainWindow: true
        )
    }

    fileprivate static func makeSeeFixtureCaptureResult(
        applicationInfo: ServiceApplicationInfo,
        windowInfo: ServiceWindowInfo
    ) -> CaptureResult {
        let metadata = CaptureMetadata(
            size: CGSize(width: 1280, height: 720),
            mode: .window,
            applicationInfo: applicationInfo,
            windowInfo: windowInfo
        )
        return CaptureResult(imageData: Data(repeating: 0xAB, count: 1024), metadata: metadata)
    }

    fileprivate static func makeSeeFixtureScreenCapture(captureResult: CaptureResult) -> StubScreenCaptureService {
        let screenCapture = StubScreenCaptureService(permissionGranted: true)
        screenCapture.defaultCaptureResult = captureResult
        return screenCapture
    }

    fileprivate static func makeSeeFixtureDetectionResult(
        snapshotId: String,
        applicationInfo: ServiceApplicationInfo,
        windowInfo: ServiceWindowInfo,
        windowBounds: CGRect
    ) -> ElementDetectionResult {
        let detectedElement = DetectedElement(
            id: "B1",
            type: .button,
            label: "OK",
            bounds: CGRect(x: 30, y: 40, width: 100, height: 30)
        )
        let detectionMetadata = DetectionMetadata(
            detectionTime: 0.1,
            elementCount: 1,
            method: "stub",
            windowContext: WindowContext(
                applicationName: applicationInfo.name,
                windowTitle: windowInfo.title,
                windowBounds: windowBounds
            )
        )
        return ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/ignored.png",
            elements: DetectedElements(buttons: [detectedElement]),
            metadata: detectionMetadata
        )
    }
}
