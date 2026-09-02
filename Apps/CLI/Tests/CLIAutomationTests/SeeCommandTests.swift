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
    @MainActor
    func `pixel publication rejects an artifact replaced after capture verification`() throws {
        let artifactURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-see-publication-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: artifactURL) }
        let verifiedData = Data("verified-pixels".utf8)
        let replacement = Data("replaced-pixels".utf8)
        #expect(verifiedData.count == replacement.count)
        try verifiedData.write(to: artifactURL, options: .atomic)
        let capture = ImageCapturedFile(
            file: SavedFile(path: artifactURL.path, mime_type: "image/png"),
            imageData: verifiedData,
            observation: ImageObservationDiagnostics(
                timings: ObservationTimings(),
                diagnostics: DesktopObservationDiagnostics()
            ),
            snapshotID: nil,
            receipt: .none
        )

        try replacement.write(to: artifactURL, options: .atomic)

        #expect(throws: DesktopObservationContentVerificationError.digestMismatch) {
            try SeeCommand.requireCurrentCaptureArtifacts([capture])
        }
    }

    @Test
    func `CLI truncation output includes deadline reached explicitly`() throws {
        let metadata = DetectionMetadata(
            detectionTime: 0,
            elementCount: 0,
            method: "OCR",
            truncationInfo: DetectionTruncationInfo(deadlineReached: true)
        )

        let summary = try #require(SeeTruncationSummary(metadata: metadata))

        #expect(summary.deadline_reached)
        #expect(summary.warning.contains("deadline"))
        #expect(!summary.warning.contains("larger AX traversal limits"))
    }

    @Test
    func `CLI deadline warning mentions larger traversal limits only for reported structural caps`() throws {
        let metadata = DetectionMetadata(
            detectionTime: 0,
            elementCount: 0,
            method: "accessibility",
            truncationInfo: DetectionTruncationInfo(
                maxDepthReached: true,
                deadlineReached: true
            )
        )

        let summary = try #require(SeeTruncationSummary(metadata: metadata))

        #expect(summary.warning.contains("--depth"))
        #expect(summary.warning.contains("larger AX traversal limits"))
        #expect(!summary.warning.contains("--max-elements"))
        #expect(!summary.warning.contains("--max-children"))
    }

    @Test
    func `CLI structural warning uses the current depth flag`() throws {
        let metadata = DetectionMetadata(
            detectionTime: 0,
            elementCount: 1,
            method: "accessibility",
            truncationInfo: DetectionTruncationInfo(maxDepthReached: true)
        )

        let summary = try #require(SeeTruncationSummary(metadata: metadata))

        #expect(summary.warning.contains("--depth"))
        #expect(!summary.warning.contains("--max-depth"))
    }

    @Test
    func `CLI incomplete AX warning does not promise that a longer timeout fixes app refusal`() throws {
        let metadata = DetectionMetadata(
            detectionTime: 0,
            elementCount: 0,
            method: "accessibility",
            truncationInfo: DetectionTruncationInfo(incompleteAccessibilityRead: true)
        )

        let summary = try #require(SeeTruncationSummary(metadata: metadata))

        #expect(!summary.deadline_reached)
        #expect(summary.incomplete_accessibility_read)
        #expect(summary.warning.contains("transient sheet"))
        #expect(summary.warning.contains("owning process or app tree"))
        #expect(summary.warning.contains("does not provide a reusable snapshot or mutation authority"))
        #expect(summary.warning.contains("increase the timeout only when the app is slow"))
    }

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
    func `See observation request preserves explicit timeout above twenty seconds`() throws {
        let command = try SeeCommand.parse(["--app", "Safari", "--timeout", "60s"])

        let request = try command.makeObservationRequest(
            target: .app(identifier: "Safari", window: .automatic)
        )

        #expect(request.timeout.overall == 60)
        #expect(request.timeout.detection == 60)
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
            ax_role: "AXButton",
            title: "Save",
            label: nil,
            value: nil,
            description: nil,
            role_description: nil,
            help: nil,
            identifier: nil,
            confidence: nil,
            bounds: UIElementBounds(CGRect(x: 0, y: 0, width: 100, height: 30)),
            is_actionable: true,
            is_enabled: true,
            is_selected: nil,
            is_value_settable: nil,
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
    @Test(arguments: [false, true])
    @MainActor
    func `config environment restores inherited values`(werePresent: Bool) async throws {
        let inherited = SeeConfigEnvironment()
        defer { inherited.restore() }
        let seeded = SeeConfigEnvironment(values: werePresent ? ["/fixture/inherited", "interactive", "false"] : [
            nil, nil, nil,
        ])
        seeded.restore()
        let directory = URL(fileURLWithPath: "/fixture/temporary")
        var resets: [SeeConfigEnvironment] = []

        let result = try await withSeeConfigEnvironment(
            directory: directory,
            resetConfiguration: { resets.append(SeeConfigEnvironment()) },
            body: { receivedDirectory in
                #expect(receivedDirectory == directory)
                #expect(SeeConfigEnvironment().values == [directory.path, "1", "1"])
                return 42
            }
        )

        #expect(result == 42)
        #expect(SeeConfigEnvironment() == seeded)
        #expect(resets == [SeeConfigEnvironment(values: [directory.path, "1", "1"]), seeded])
    }

    @Test
    @MainActor
    func `config environment restores nested throwing bodies`() async throws {
        let inherited = SeeConfigEnvironment()
        defer { inherited.restore() }
        let seeded = SeeConfigEnvironment(values: ["/fixture/inherited", "", "false"])
        seeded.restore()
        let outer = URL(fileURLWithPath: "/fixture/outer")
        let inner = URL(fileURLWithPath: "/fixture/inner")
        var resets: [SeeConfigEnvironment] = []

        do {
            try await withSeeConfigEnvironment(
                directory: outer,
                resetConfiguration: { resets.append(SeeConfigEnvironment()) },
                body: { _ in
                    do {
                        try await withSeeConfigEnvironment(
                            directory: inner,
                            resetConfiguration: { resets.append(SeeConfigEnvironment()) },
                            body: { _ in
                                #expect(SeeConfigEnvironment().values == [inner.path, "1", "1"])
                                throw SeeConfigEnvironmentTestError.failed
                            }
                        )
                        Issue.record("Expected the inner configuration body to throw")
                    } catch SeeConfigEnvironmentTestError.failed {}
                    #expect(SeeConfigEnvironment().values == [outer.path, "1", "1"])
                    throw SeeConfigEnvironmentTestError.failed
                }
            )
            Issue.record("Expected the outer configuration body to throw")
        } catch SeeConfigEnvironmentTestError.failed {}

        #expect(SeeConfigEnvironment() == seeded)
        #expect(resets == [
            SeeConfigEnvironment(values: [outer.path, "1", "1"]),
            SeeConfigEnvironment(values: [inner.path, "1", "1"]),
            SeeConfigEnvironment(values: [outer.path, "1", "1"]),
            seeded,
        ])
    }

    @Test
    @MainActor
    func `tree only See propagates its remaining timeout to accessibility inspection`() async throws {
        try await self.withTempConfigEnv { _ in
            let fixture = Self.makeSeeCommandRuntimeFixture()
            let automation = StubAutomationService()
            automation.inspectAccessibilityTreeHandler = { _ in fixture.detectionResult }
            let (context, _) = Self.makeSeeCommandRuntimeContext(
                automation: automation,
                screenCapture: fixture.screenCapture,
                applicationInfo: fixture.applicationInfo,
                windowInfo: fixture.windowInfo
            )

            let result = try await InProcessCommandRunner.run(
                [
                    "see",
                    "--app", fixture.applicationInfo.name,
                    "--tree",
                    "--no-screenshot",
                    "--timeout", "60s",
                    "--json",
                ],
                services: context.services
            )

            #expect(result.exitStatus == 0)
            let inspectionContext = try #require(automation.inspectAccessibilityTreeCalls.compactMap(\.self).first)
            let timeout = try #require(inspectionContext.accessibilityTimeoutSeconds)
            #expect(timeout > 50)
            #expect(timeout < 60)
        }
    }

    @Test
    @MainActor
    func `tree only See fails instead of publishing an empty deadline result`() async throws {
        try await self.withTempConfigEnv { _ in
            let fixture = Self.makeSeeCommandRuntimeFixture()
            let automation = StubAutomationService()
            automation.inspectAccessibilityTreeHandler = { context in
                let timeout = try #require(context?.accessibilityTimeoutSeconds)
                #expect(timeout > 4)
                #expect(timeout <= 5)
                return ElementDetectionResult(
                    snapshotId: "system-settings-empty-deadline",
                    screenshotPath: "",
                    elements: DetectedElements(),
                    metadata: DetectionMetadata(
                        detectionTime: 0.288,
                        elementCount: 0,
                        method: "AXorcist",
                        truncationInfo: DetectionTruncationInfo(deadlineReached: true)
                    )
                )
            }
            let (context, _) = Self.makeSeeCommandRuntimeContext(
                automation: automation,
                screenCapture: fixture.screenCapture,
                applicationInfo: fixture.applicationInfo,
                windowInfo: fixture.windowInfo
            )

            let result = try await InProcessCommandRunner.run(
                [
                    "see",
                    "--app", fixture.applicationInfo.name,
                    "--tree",
                    "--no-screenshot",
                    "--timeout", "5s",
                    "--json",
                ],
                services: context.services
            )

            #expect(result.exitStatus == 1)
            #expect(result.combinedOutput.contains("Element detection timed out after 5s"))
            #expect(!result.combinedOutput.contains("\"snapshot_id\""))
            #expect(try await context.snapshots.listSnapshots().isEmpty)
        }
    }

    @Test
    @MainActor
    func `tree only See preserves useful partial evidence at its deadline`() async throws {
        try await self.withTempConfigEnv { _ in
            let fixture = Self.makeSeeCommandRuntimeFixture()
            let automation = StubAutomationService()
            let partialElement = try #require(fixture.detectionResult.elements.all.first)
            automation.inspectAccessibilityTreeHandler = { _ in
                ElementDetectionResult(
                    snapshotId: "partial-deadline",
                    screenshotPath: "",
                    elements: DetectedElements(buttons: [partialElement]),
                    metadata: DetectionMetadata(
                        detectionTime: 4.75,
                        elementCount: 1,
                        method: "AXorcist",
                        windowContext: fixture.detectionResult.metadata.windowContext,
                        truncationInfo: DetectionTruncationInfo(
                            deadlineReached: true,
                            incompleteAccessibilityRead: true
                        )
                    )
                )
            }
            let (context, _) = Self.makeSeeCommandRuntimeContext(
                automation: automation,
                screenCapture: fixture.screenCapture,
                applicationInfo: fixture.applicationInfo,
                windowInfo: fixture.windowInfo
            )

            let result = try await InProcessCommandRunner.run(
                [
                    "see",
                    "--app", fixture.applicationInfo.name,
                    "--tree",
                    "--no-screenshot",
                    "--timeout", "5s",
                    "--json",
                ],
                services: context.services
            )

            #expect(result.exitStatus == 0)
            #expect(result.combinedOutput.contains(partialElement.id))
            #expect(result.combinedOutput.contains("\"deadline_reached\" : true") ||
                result.combinedOutput.contains("\"deadline_reached\":true"))
        }
    }

    @Test
    @MainActor
    func `tree only See labels application fallback as observation only`() async throws {
        try await self.runApplicationPartialSeeAssertions()
    }

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
                    "--web-focus",
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
                    "--timeout", "1s",
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
                    "--web-focus",
                    "--timeout", "1s",
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
                    "--web-focus",
                    "--timeout", "1s",
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
                    "--web-focus",
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
                    "--web-focus",
                    "--timeout", "1s",
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
            #expect(context.snapshots.detectionResults.isEmpty)
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
            value: "0.5",
            bounds: CGRect(x: 50, y: 60, width: 34, height: 34),
            isEnabled: true,
            isSelected: true,
            attributes: [
                "role": "AXButton",
                "description": "Wingman Grindr Session Helper",
                "roleDescription": "Pop Up Button",
                "help": "Pinned extension button",
                "identifier": "wingman-session-helper",
                "isActionable": "true",
                "isValueSettable": "true",
                "axEnabledKnown": "true",
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
            let rawResponse = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let rawData = try #require(rawResponse["data"] as? [String: Any])
            let element = try #require(response.data.ui_elements.first)

            #expect(response.success == true)
            #expect(rawResponse["success"] as? Bool == true)
            #expect(rawData["success"] == nil)
            #expect(element.description == "Wingman Grindr Session Helper")
            #expect(element.ax_role == "AXButton")
            #expect(element.role_description == "Pop Up Button")
            #expect(element.help == "Pinned extension button")
            #expect(element.identifier == "wingman-session-helper")
            #expect(element.value == "0.5")
            #expect(element.is_actionable)
            #expect(element.is_enabled == true)
            #expect(element.is_selected == true)
            #expect(element.is_value_settable == true)
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
            #expect(screenCapture.captureVisualizerModes == [.none])
        }
    }

    @MainActor
    func withTempConfigEnv<T>(
        _ body: @escaping @MainActor (URL) async throws -> T
    ) async throws -> T {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(at: tempDir) }
        return try await withSeeConfigEnvironment(
            directory: tempDir,
            resetConfiguration: {
                #if DEBUG
                ConfigurationManager.shared.resetForTesting()
                #endif
            },
            body: body
        )
    }
}

private struct SeeConfigEnvironment: Equatable {
    private static let names = [
        "PEEKABOO_CONFIG_DIR", "PEEKABOO_CONFIG_NONINTERACTIVE", "PEEKABOO_CONFIG_DISABLE_MIGRATION",
    ]

    let values: [String?]

    init(values: [String?]) {
        precondition(values.count == Self.names.count)
        self.values = values
    }

    init() {
        self.values = Self.names.map { name in getenv(name).map { String(cString: $0) } }
    }

    func restore() {
        for (name, value) in zip(Self.names, self.values) {
            if let value {
                setenv(name, value, 1)
            } else {
                unsetenv(name)
            }
        }
    }
}

private enum SeeConfigEnvironmentTestError: Error {
    case failed
}

/// Callers belong to the serialized See runtime suite; regression tests inject an inert reset callback.
/// Run focused proof with --no-parallel: environment changes also affect sibling suites.
@MainActor
private func withSeeConfigEnvironment<T>(
    directory: URL,
    resetConfiguration: () -> Void,
    body: @MainActor (URL) async throws -> T
) async throws -> T {
    let inherited = SeeConfigEnvironment()
    SeeConfigEnvironment(values: [directory.path, "1", "1"]).restore()
    resetConfiguration()
    defer {
        inherited.restore()
        resetConfiguration()
    }
    return try await body(directory)
}

extension SeeCommandRuntimeTests {
    @Test
    @MainActor
    func `combined See returns typed failure for legacy exact empty accessibility evidence`() async throws {
        try await self.withTempConfigEnv { _ in
            let fixture = Self.makeSeeCommandRuntimeFixture()
            let automation = StubAutomationService()
            var detectionContext: WindowContext?
            automation.detectElementsHandler = { _, snapshotID, context in
                detectionContext = context
                return ElementDetectionResult(
                    snapshotId: snapshotID ?? "legacy-empty",
                    screenshotPath: "",
                    elements: DetectedElements(),
                    metadata: DetectionMetadata(
                        detectionTime: 0.1,
                        elementCount: 0,
                        method: "legacy AX"
                    )
                )
            }
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
                    "--app", fixture.applicationInfo.name,
                    "--path", outputURL.path,
                    "--json",
                ],
                services: context.services
            )
            let envelope = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
            )
            let error = try #require(envelope["error"] as? [String: Any])

            #expect(result.exitStatus == 1)
            #expect(result.stderr.isEmpty)
            #expect(envelope["success"] as? Bool == false)
            #expect(error["code"] as? String == "ACCESSIBILITY_INCOMPLETE")
            #expect(error["retry_safe"] as? Bool == true)
            #expect(error["mutation_dispatched"] as? Bool == false)
            #expect((error["message"] as? String)?.contains("Exact window 101") == true)
            #expect(detectionContext?.allowApplicationScopedAccessibilityFallback != true)
            #expect(FileManager.default.fileExists(atPath: outputURL.path))
            #expect(try await context.snapshots.listSnapshots().isEmpty)
        }
    }

    @Test
    @MainActor
    func `screenshot only See preserves exact empty accessibility success`() async throws {
        try await self.withTempConfigEnv { _ in
            let fixture = Self.makeSeeCommandRuntimeFixture()
            let automation = StubAutomationService()
            var detectionCalled = false
            automation.detectElementsHandler = { _, snapshotID, _ in
                detectionCalled = true
                return ElementDetectionResult(
                    snapshotId: snapshotID ?? "unused-empty",
                    screenshotPath: "",
                    elements: DetectedElements(),
                    metadata: DetectionMetadata(detectionTime: 0, elementCount: 0, method: "legacy AX")
                )
            }
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
                    "--app", fixture.applicationInfo.name,
                    "--no-elements",
                    "--path", outputURL.path,
                    "--json",
                ],
                services: context.services
            )
            let envelope = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
            )

            #expect(result.exitStatus == 0)
            #expect(result.stderr.isEmpty)
            #expect(envelope["success"] as? Bool == true)
            #expect(detectionCalled == false)
            #expect(FileManager.default.fileExists(atPath: outputURL.path))
        }
    }

    @Test
    @MainActor
    func `tree only See returns typed retry-safe failure for Calendar-shaped incomplete evidence`() async throws {
        try await self.withTempConfigEnv { _ in
            let fixture = Self.makeSeeCommandRuntimeFixture()
            let automation = StubAutomationService()
            automation.inspectAccessibilityTreeHandler = { _ in
                ElementDetectionResult(
                    snapshotId: "calendar-empty-incomplete",
                    screenshotPath: "",
                    elements: DetectedElements(),
                    metadata: DetectionMetadata(
                        detectionTime: 0.35,
                        elementCount: 0,
                        method: "AXorcist",
                        windowContext: WindowContext(
                            applicationName: "Calendar",
                            applicationBundleId: "com.apple.iCal",
                            applicationProcessId: 858,
                            windowTitle: "Calendar",
                            windowID: 119
                        ),
                        truncationInfo: DetectionTruncationInfo(incompleteAccessibilityRead: true)
                    )
                )
            }
            let (context, _) = Self.makeSeeCommandRuntimeContext(
                automation: automation,
                screenCapture: fixture.screenCapture,
                applicationInfo: fixture.applicationInfo,
                windowInfo: fixture.windowInfo
            )

            let result = try await InProcessCommandRunner.run(
                [
                    "see",
                    "--app", fixture.applicationInfo.name,
                    "--tree",
                    "--no-screenshot",
                    "--timeout", "5s",
                    "--json",
                ],
                services: context.services
            )
            let envelope = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
            )
            let error = try #require(envelope["error"] as? [String: Any])

            #expect(result.exitStatus == 1)
            #expect(result.stderr.isEmpty)
            #expect(envelope["success"] as? Bool == false)
            #expect(envelope["data"] is NSNull)
            #expect(envelope["effect"] == nil)
            #expect(error["code"] as? String == "ACCESSIBILITY_INCOMPLETE")
            #expect(error["retry_safe"] as? Bool == true)
            #expect(error["mutation_dispatched"] as? Bool == false)
            #expect((error["message"] as? String)?.contains("fresh observation") == true)
            #expect((error["message"] as? String)?.contains("transient sheet") == true)
            #expect((error["message"] as? String)?.contains("owning process or app tree") == true)
            #expect((error["message"] as? String)?.contains("read-only dialog elements") == true)
            #expect((error["message"] as? String)?.contains(
                "does not provide a reusable snapshot or mutation authority"
            ) == true)
            #expect((error["hint"] as? String)?.contains("screenshot/OCR") == true)
            #expect((error["hint"] as? String)?.contains("increase the timeout only when the app is slow") == true)
            #expect(!result.stdout.contains("snapshot_id"))
            #expect(try await context.snapshots.listSnapshots().isEmpty)
        }
    }

    @Test
    @MainActor
    func `tree only See does not claim exact incomplete code without a resolved window`() async throws {
        try await self.withTempConfigEnv { _ in
            let fixture = Self.makeSeeCommandRuntimeFixture()
            let automation = StubAutomationService()
            automation.inspectAccessibilityTreeHandler = { _ in
                ElementDetectionResult(
                    snapshotId: "unresolved-empty-incomplete",
                    screenshotPath: "",
                    elements: DetectedElements(),
                    metadata: DetectionMetadata(
                        detectionTime: 0.1,
                        elementCount: 0,
                        method: "AXorcist",
                        truncationInfo: DetectionTruncationInfo(incompleteAccessibilityRead: true)
                    )
                )
            }
            let (context, _) = Self.makeSeeCommandRuntimeContext(
                automation: automation,
                screenCapture: fixture.screenCapture,
                applicationInfo: fixture.applicationInfo,
                windowInfo: fixture.windowInfo
            )

            let result = try await InProcessCommandRunner.run(
                ["see", "--app", fixture.applicationInfo.name, "--tree", "--no-screenshot", "--json"],
                services: context.services
            )
            let envelope = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
            )
            let error = try #require(envelope["error"] as? [String: Any])

            #expect(result.exitStatus == 1)
            #expect(error["code"] as? String == "UNKNOWN_ERROR")
            #expect(error["code"] as? String != "ACCESSIBILITY_INCOMPLETE")
            #expect(error["retry_safe"] == nil)
            #expect(error["mutation_dispatched"] == nil)
        }
    }

    struct RuntimeFixture {
        let snapshotId: String
        let applicationInfo: ServiceApplicationInfo
        let windowInfo: ServiceWindowInfo
        let screenCapture: StubScreenCaptureService
        let detectionResult: ElementDetectionResult
    }

    static func makeSeeCommandRuntimeFixture() -> RuntimeFixture {
        let snapshotId = SnapshotReference.generate().rawValue
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

    static func makeSeeCommandRuntimeContext(
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
            processStartIdentity: 4242,
            bundleIdentifier: "com.example.app",
            name: "ExampleApp",
            isActive: true,
            windowCount: 1
        )
    }

    fileprivate static func makeSeeFixtureWindowInfo(windowBounds: CGRect) -> ServiceWindowInfo {
        let mutationIdentity = WindowMutationIdentity(
            windowID: 101,
            ownerProcessIdentifier: 4242,
            ownerProcessStartIdentity: 4242,
            capturedBounds: windowBounds
        )
        return ServiceWindowInfo(
            windowID: 101,
            title: "Main Window",
            bounds: windowBounds,
            isMainWindow: true,
            mutationIdentity: mutationIdentity
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
                applicationBundleId: applicationInfo.bundleIdentifier,
                applicationProcessId: applicationInfo.processIdentifier,
                windowTitle: windowInfo.title,
                windowID: windowInfo.windowID,
                windowBounds: windowBounds,
                windowMutationIdentity: windowInfo.mutationIdentity
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
