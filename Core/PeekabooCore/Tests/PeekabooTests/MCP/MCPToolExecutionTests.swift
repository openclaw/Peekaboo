import AppKit
import Foundation
import ImageIO
import MCP
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
import UniformTypeIdentifiers
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore
@testable import PeekabooVisualizer

@Suite(.serialized)
struct MCPToolExecutionTests {
    @Test
    @MainActor
    func `Mock application request quit preserves legacy delegation`() async throws {
        let applications = MockApplicationService()

        #expect(try await applications.quitApplication(request: ApplicationQuitRequest(
            identifier: "Missing App",
            force: false)))
        await #expect(throws: PeekabooError.self) {
            try await applications.quitApplication(request: ApplicationQuitRequest(
                identifier: "PID:42",
                force: false,
                expectedIdentity: AutomationTestFixtures.processIdentity(processIdentifier: 42)))
        }
    }

    // MARK: - Sleep Tool Tests

    @Test
    func `Sleep tool execution with valid duration`() async throws {
        try await MCPToolTestHelpers.withContext {
            let tool = SleepTool()
            // Use a shorter duration for testing
            let args = ToolArguments(raw: ["duration": 1])

            let start = Date()
            let response = try await tool.execute(arguments: args)
            let elapsed = Date().timeIntervalSince(start)

            #expect(response.isError == false)
            #expect(elapsed >= 0)

            if case let .text(text: message, annotations: _, _meta: _) = response.content.first {
                #expect(message.contains("Paused") || message.contains("Sleep"))
            }
        }
    }

    @Test
    func `Sleep tool with missing duration`() async throws {
        try await MCPToolTestHelpers.withContext {
            let tool = SleepTool()
            let args = ToolArguments(raw: [:])

            let response = try await tool.execute(arguments: args)
            #expect(response.isError == true)

            if case let .text(text: error, annotations: _, _meta: _) = response.content.first {
                #expect(error.contains("duration"))
            }
        }
    }

    // MARK: - Permissions Tool Tests

    @Test
    func `Image tool returns MCP error response when screen recording is missing`() async throws {
        let screenCapture = await MainActor.run { MockScreenCaptureService(screenRecordingGranted: false) }
        let context = await MCPToolTestHelpers.makeLegacyContext(screenCapture: screenCapture)
        let tool = ImageTool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "path": "/tmp/peekaboo-missing-permission.png",
            "format": "png",
        ]))

        #expect(response.isError == true)
        let captureAttemptCount = await MainActor.run { screenCapture.captureAttemptCount }
        #expect(captureAttemptCount == 0)

        guard case let .text(text: output, annotations: _, _meta: _) = response.content.first else {
            Issue.record("Expected text error response")
            return
        }

        #expect(output.contains("Screen Recording permission is required"))
        #expect(output.contains("System Settings > Privacy & Security > Screen Recording"))
    }

    @Test
    func `Image tool menubar target uses observation menu bar bounds`() async throws {
        let screen = ScreenInfo(
            index: 0,
            name: "Main",
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1080),
            isPrimary: true,
            scaleFactor: 2,
            displayID: 1)
        let screenCapture = await MainActor.run { MockScreenCaptureService(screenRecordingGranted: true) }
        let screens = await MainActor.run { MockScreenService(screens: [screen]) }
        let context = await MCPToolTestHelpers.makeLegacyContext(screenCapture: screenCapture, screens: screens)
        let tool = ImageTool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "app_target": "menubar",
            "format": "data",
        ]))

        #expect(response.isError == false)
        #expect(await MainActor.run { screenCapture.lastArea } == CGRect(x: 0, y: 1080, width: 1728, height: 37))
        #expect(await MainActor.run { screenCapture.captureAttemptCount } == 1)
    }

    @Test
    func `Image tool native scale reaches observation capture`() async throws {
        let screenCapture = await MainActor.run { MockScreenCaptureService(screenRecordingGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(screenCapture: screenCapture)
        let tool = ImageTool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "format": "data",
            "scale": "native",
        ]))

        #expect(response.isError == false)
        #expect(await MainActor.run { screenCapture.lastScale } == .native)
    }

    @Test
    func `Image tool returns MCP error for empty inline capture data`() async throws {
        let screenCapture = await MainActor.run {
            MockScreenCaptureService(screenRecordingGranted: true, imageData: Data())
        }
        let context = await MCPToolTestHelpers.makeLegacyContext(screenCapture: screenCapture)
        let tool = ImageTool(context: context)
        let outputPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-mcp-empty-image-\(UUID().uuidString).png")
            .path
        defer { try? FileManager.default.removeItem(atPath: outputPath) }

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "path": outputPath,
            "format": "data",
        ]))

        #expect(response.isError == true)
        #expect(!FileManager.default.fileExists(atPath: outputPath))
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(true))
        guard case let .text(text: output, annotations: _, _meta: _) = response.content.first else {
            Issue.record("Expected text error response")
            return
        }
        #expect(output == "Capture produced no image data and no saved file could be read")
    }

    @Test
    func `Image tool downscales high-res image when format is data`() async throws {
        let highResPNG = Self.makePNGData(width: 3000, height: 2000)
        let screenCapture = await MainActor.run {
            MockScreenCaptureService(screenRecordingGranted: true, imageData: highResPNG)
        }
        let context = await MCPToolTestHelpers.makeLegacyContext(screenCapture: screenCapture)
        let tool = ImageTool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "format": "data",
        ]))

        #expect(response.isError == false)
        guard case let .image(data: responseBase64, mimeType: mimeType, annotations: _, _meta: _) = response.content
            .first
        else {
            Issue.record("Expected image response")
            return
        }
        guard let responseData = Data(base64Encoded: responseBase64) else {
            Issue.record("Expected Base64 image data")
            return
        }

        #expect(mimeType == "image/png")
        #expect(Self.imageDimensions(from: responseData) == CGSize(width: 1500, height: 1000))
    }

    @Test
    func `Image tool downscales high-res inline image to custom max_dimension`() async throws {
        let highResPNG = Self.makePNGData(width: 3000, height: 2000)
        let captureMetadata = CaptureMetadata(
            size: CGSize(width: 3000, height: 2000),
            mode: .screen,
            displayInfo: DisplayInfo(
                index: 0,
                name: "Retina Display",
                bounds: CGRect(x: 0, y: 0, width: 1500, height: 1000),
                scaleFactor: 2),
            diagnostics: CaptureDiagnostics(
                requestedScale: .native,
                nativeScale: 2,
                outputScale: 2,
                scaleSource: "screenBackingScaleFactor",
                finalPixelSize: CGSize(width: 3000, height: 2000)))
        let screenCapture = await MainActor.run {
            MockScreenCaptureService(
                screenRecordingGranted: true,
                imageData: highResPNG,
                metadata: captureMetadata)
        }
        let context = await MCPToolTestHelpers.makeLegacyContext(screenCapture: screenCapture)
        let tool = ImageTool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "format": "data",
            "max_dimension": 600,
        ]))

        #expect(response.isError == false)
        guard case let .image(data: responseBase64, mimeType: _, annotations: _, _meta: _) = response.content.first
        else {
            Issue.record("Expected image response")
            return
        }
        guard let responseData = Data(base64Encoded: responseBase64) else {
            Issue.record("Expected Base64 image data")
            return
        }

        #expect(Self.imageDimensions(from: responseData) == CGSize(width: 600, height: 400))
        let coordinateContext = try #require(Self.coordinateContext(from: response))
        #expect(Self.size(from: coordinateContext["delivered_image_size"]) == CGSize(width: 600, height: 400))
        #expect(Self.rect(from: coordinateContext["logical_bounds"]) == CGRect(x: 0, y: 0, width: 1500, height: 1000))
        #expect(Self.double(from: coordinateContext["native_scale"]) == 2)
        #expect(Self.double(from: coordinateContext["output_scale"]) == 0.4)
    }

    @Test
    func `Image tool downscales saved image when max_dimension is set`() async throws {
        let highResPNG = Self.makePNGData(width: 3000, height: 2000)
        let screenCapture = await MainActor.run {
            MockScreenCaptureService(screenRecordingGranted: true, imageData: highResPNG)
        }
        let context = await MCPToolTestHelpers.makeLegacyContext(screenCapture: screenCapture)
        let tool = ImageTool(context: context)
        let outputPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-mcp-downscaled-\(UUID().uuidString).png")
            .path
        defer { try? FileManager.default.removeItem(atPath: outputPath) }

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "path": outputPath,
            "format": "png",
            "max_dimension": 600,
        ]))

        #expect(response.isError == false)
        #expect(FileManager.default.fileExists(atPath: outputPath))
        let savedData = try Data(contentsOf: URL(fileURLWithPath: outputPath))
        #expect(Self.imageDimensions(from: savedData) == CGSize(width: 600, height: 400))
    }

    @Test
    func `Image tool downscales saved fallback when capture data is empty`() async throws {
        let highResPNG = Self.makePNGData(width: 3000, height: 2000)
        let context = await MCPToolTestHelpers.makeLegacyContext()
        let tool = ImageTool(context: context)
        let outputPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-mcp-downscaled-fallback-\(UUID().uuidString).png")
            .path
        defer { try? FileManager.default.removeItem(atPath: outputPath) }
        try highResPNG.write(to: URL(fileURLWithPath: outputPath))
        let capture = CaptureResult(
            imageData: Data(),
            savedPath: outputPath,
            metadata: CaptureMetadata(size: CGSize(width: 3000, height: 2000), mode: .screen))
        let observation = DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .screen(index: 0)),
            capture: capture,
            elements: nil)
        let captureSet = ImageCaptureSet(
            captures: [capture],
            actionResult: UIAutomationActionResult(payload: observation, outcome: nil))
        let request = try ImageRequest(arguments: ToolArguments(raw: [
            "format": "data",
            "max_dimension": 600,
        ]))

        let result = try tool.downscaledCaptureSetIfNeeded(captureSet, request: request)

        let deliveredCapture = try #require(result.captures.first)
        #expect(Self.imageDimensions(from: deliveredCapture.imageData) == CGSize(width: 600, height: 400))
        #expect(deliveredCapture.metadata.size == CGSize(width: 600, height: 400))
        let savedData = try Data(contentsOf: URL(fileURLWithPath: outputPath))
        #expect(Self.imageDimensions(from: savedData) == CGSize(width: 600, height: 400))
    }

    @Test
    func `Image tool rejects nonpositive max_dimension`() async throws {
        let screenCapture = await MainActor.run { MockScreenCaptureService(screenRecordingGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(screenCapture: screenCapture)
        let tool = ImageTool(context: context)

        await #expect(throws: PeekabooError.self) {
            _ = try await tool.execute(arguments: ToolArguments(raw: [
                "format": "data",
                "max_dimension": 0,
            ]))
        }
    }

    // MARK: - Application and Window List Tool Tests

    @Test
    func `Application list preserves unknown hidden state and partial warnings`() async throws {
        let warning = "Application metadata timed out for PID 41; hidden state is unknown"
        let app = ServiceApplicationInfo(
            processIdentifier: 41,
            processStartIdentity: 7,
            bundleIdentifier: nil,
            name: "Poisoned Helper",
            isHidden: false,
            isHiddenKnown: false,
            windowIDs: [],
            metadataWarnings: [warning])
        let prohibited = ServiceApplicationInfo(
            processIdentifier: 42,
            processStartIdentity: 8,
            bundleIdentifier: "com.example.Daemon",
            name: "System Daemon",
            activationPolicy: .prohibited,
            metadataWarnings: ["filtered prohibited warning"])
        let applications = await MainActor.run { MockApplicationService(applications: [app, prohibited]) }
        let context = await MCPToolTestHelpers.makeLegacyContext(applications: applications)

        let response = try await AppTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "list",
        ]))

        #expect(!response.isError)
        let text = response.content.compactMap { content -> String? in
            guard case let .text(value, _, _) = content else { return nil }
            return value
        }.joined(separator: "\n")
        #expect(text.contains("hidden state unknown"))
        #expect(text.contains(warning))
        #expect(!text.contains("System Daemon"))
        #expect(!text.contains("filtered prohibited warning"))
        guard case let .object(meta) = response.meta,
              case let .array(rows)? = meta["apps"],
              case let .object(row) = rows.first,
              case .null? = row["is_hidden"],
              case let .array(warnings)? = meta["warnings"]
        else {
            Issue.record("Expected partial application metadata")
            return
        }
        #expect(rows.count == 1)
        #expect(warnings == [.string(warning)])
    }

    @Test
    func `Window list returns IDs bounds and off-screen state`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 1,
            bundleIdentifier: "com.apple.finder",
            name: "Finder")
        let window = ServiceWindowInfo(
            windowID: 42,
            title: "Desktop",
            bounds: CGRect(x: 10, y: 20, width: 800, height: 600),
            index: 0,
            isOffScreen: true,
            observationCapability: .pixelsOnly(reason: .noMatchingAccessibilityWindow))
        let incompleteWindow = ServiceWindowInfo(
            windowID: 43,
            title: "Partial AX inventory",
            bounds: CGRect(x: 30, y: 40, width: 900, height: 700),
            index: 1,
            observationCapability: .unknown(reason: .accessibilityEnumerationIncomplete))
        let applications = await MainActor.run {
            MockApplicationService(
                applications: [app],
                windowsByIdentifier: ["Finder": [window, incompleteWindow]])
        }
        let context = await MCPToolTestHelpers.makeLegacyContext(applications: applications)
        let response = try await WindowTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "list",
            "app": "Finder",
        ]))

        #expect(!response.isError)
        guard case let .text(text: output, annotations: _, _meta: _) = response.content.first else {
            Issue.record("Expected text response for window listing")
            return
        }
        #expect(output.contains("ID: 42"))
        #expect(output.contains("Bounds: 10, 20 800×600"))
        #expect(output.contains("OFF-SCREEN"))
        #expect(output.contains("Observation: pixels_only"))
        #expect(output.contains("no_matching_accessibility_window"))
        #expect(output.contains("no_elements: true"))
        #expect(output.contains("Observation: unknown"))
        #expect(output.contains("accessibility_enumeration_incomplete"))

        let metadata = try #require(response.meta?.objectValue)
        let rows = try #require(metadata["windows"]?.arrayValue)
        #expect(rows.count == 2)
        let row = try #require(rows.first?.objectValue)
        #expect(Set(row.keys) == [
            "window_id",
            "observation_capability",
            "observation_capability_reason",
        ])
        #expect(row["window_id"] == .int(42))
        #expect(row["observation_capability"] == .string("pixels_only"))
        #expect(row["observation_capability_reason"] == .string("no_matching_accessibility_window"))
        let incompleteRow = try #require(rows.last?.objectValue)
        #expect(incompleteRow["observation_capability"] == .string("unknown"))
        #expect(incompleteRow["observation_capability_reason"] ==
            .string("accessibility_enumeration_incomplete"))
    }

    @Test
    func `See tool summary surfaces enriched element metadata`() async throws {
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot-1",
            screenshotPath: "/tmp/peekaboo-see-test.png",
            elements: DetectedElements(
                buttons: [
                    DetectedElement(
                        id: "B1",
                        type: .button,
                        label: "OK",
                        value: "Confirm",
                        bounds: CGRect(x: 540, y: 320, width: 80, height: 32),
                        isEnabled: true,
                        attributes: [
                            "description": "Confirms the dialog",
                            "help": "Press to continue",
                            "identifier": "confirm-button",
                            "keyboardShortcut": "Return",
                        ]),
                ]),
            metadata: DetectionMetadata(
                detectionTime: 0.02,
                elementCount: 1,
                method: "mock"))
        let automation = await MainActor.run {
            MockAutomationService(
                accessibilityGranted: true,
                detectionResult: detectionResult)
        }
        let screenCapture = await MainActor.run { MockScreenCaptureService(screenRecordingGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(
            automation: automation,
            screenCapture: screenCapture)
        let tool = SeeTool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [:]))
        #expect(response.isError == false)

        guard case let .text(text: output, annotations: _, _meta: _) = response.content.first else {
            Issue.record("Expected text response for see output")
            return
        }

        #expect(output.contains("size 80×32"))
        #expect(output.contains("value: \"Confirm\""))
        #expect(output.contains("desc: \"Confirms the dialog\""))
        #expect(output.contains("help: \"Press to continue\""))
        #expect(output.contains("shortcut: Return"))
        #expect(output.contains("identifier: confirm-button"))

        guard case let .object(meta) = response.meta,
              case let .string(snapshotID)? = meta["snapshot_id"],
              case let .object(coordinateContext)? = meta["coordinate_context"],
              case let .string(referenceID)? = coordinateContext["reference_id"]
        else {
            Issue.record("Expected See metadata to contain a referenced coordinate context")
            return
        }
        #expect(referenceID == snapshotID)
        let storedSnapshot = await UISnapshotManager.shared.getSnapshot(id: snapshotID)
        let storedContext = await storedSnapshot?.screenshotCoordinateContext
        #expect(storedContext?.referenceID == snapshotID)
        #expect(storedContext?.logicalSpace == .globalDisplayPoints)
    }

    @Test
    func `timed out background See tool removes its snapshot`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run {
            MockAutomationService(
                accessibilityGranted: true,
                detectionError: POSIXError(.ETIMEDOUT))
        }
        let snapshots = await MainActor.run { InMemorySnapshotManager() }
        let context = await MCPToolTestHelpers.makeLegacyContext(
            automation: automation,
            snapshots: snapshots)
        let tool = SeeTool(context: context)

        let response = try await context.execute(tool: tool, arguments: ToolArguments(raw: [:]))

        #expect(response.isError)
        #expect(try await snapshots.listSnapshots().isEmpty)
        let remainingSnapshotCount = try await snapshots.cleanAllSnapshots()
        #expect(remainingSnapshotCount == 0)
        #expect(await UISnapshotManager.shared.getSnapshot(id: nil) == nil)
        await UISnapshotManager.shared.removeAllSnapshots()
    }

    @Test
    func `See tool app target detects against resolved observation window`() async throws {
        let graph = try await MainActor.run {
            try Self.makeWindowedTestGraph()
        }
        let app = try #require(graph.applications.first)
        let windows = try #require(graph.nodes.first?.windows)
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot-2",
            screenshotPath: "/tmp/peekaboo-see-observation-test.png",
            elements: DetectedElements(buttons: [
                DetectedElement(
                    id: "B1",
                    type: .button,
                    label: "Continue",
                    bounds: CGRect(x: 10, y: 10, width: 80, height: 30)),
            ]),
            metadata: DetectionMetadata(detectionTime: 0.01, elementCount: 1, method: "mock"))
        let automation = await MainActor.run {
            MockAutomationService(accessibilityGranted: true, detectionResult: detectionResult)
        }
        let applications = await MainActor.run {
            MockApplicationService(graph: graph)
        }
        let screenCapture = await MainActor.run {
            MockScreenCaptureService(
                screenRecordingGranted: true,
                windowMetadata: Self.captureMetadata(application: app, windows: windows))
        }
        let context = await MCPToolTestHelpers.makeLegacyContext(
            automation: automation,
            screenCapture: screenCapture,
            applications: applications)
        let tool = SeeTool(context: context)
        let outputPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-mcp-see-\(UUID().uuidString).png")
            .path

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "path": outputPath,
            "app_target": app.name,
        ]))

        #expect(response.isError == false)
        #expect(await MainActor.run { screenCapture.lastWindowID } == 42)
        #expect(await MainActor.run { screenCapture.captureAttemptCount } == 1)
        let detectedContext = await MainActor.run { automation.lastWindowContext }
        #expect(detectedContext?.applicationName == app.name)
        #expect(detectedContext?.windowID == 42)
    }

    @Test
    func `See tool PID target with window index uses shared observation parser`() async throws {
        let graph = try await MainActor.run {
            try Self.makeWindowedTestGraph()
        }
        let app = try #require(graph.applications.first)
        let windows = try #require(graph.nodes.first?.windows)
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot-pid-window",
            screenshotPath: "/tmp/peekaboo-see-pid-window-test.png",
            elements: DetectedElements(buttons: [
                DetectedElement(
                    id: "B1",
                    type: .button,
                    label: "Continue",
                    bounds: CGRect(x: 10, y: 10, width: 80, height: 30)),
            ]),
            metadata: DetectionMetadata(detectionTime: 0.01, elementCount: 1, method: "mock"))
        let automation = await MainActor.run {
            MockAutomationService(accessibilityGranted: true, detectionResult: detectionResult)
        }
        let applications = await MainActor.run {
            MockApplicationService(graph: graph)
        }
        let screenCapture = await MainActor.run {
            MockScreenCaptureService(
                screenRecordingGranted: true,
                windowMetadata: Self.captureMetadata(application: app, windows: windows))
        }
        let context = await MCPToolTestHelpers.makeLegacyContext(
            automation: automation,
            screenCapture: screenCapture,
            applications: applications)
        let tool = SeeTool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "app_target": "PID:\(app.processIdentifier):2",
        ]))

        #expect(response.isError == false)
        #expect(await MainActor.run { screenCapture.lastWindowID } == 42)
    }

    @MainActor
    private static func makeWindowedTestGraph() throws -> LinkedApplicationInventoryGraph {
        let app = AutomationTestFixtures.application(
            processIdentifier: 1234,
            processStartIdentity: 700,
            bundleIdentifier: "com.test.zephyr",
            name: "Zephyr Agency",
            isActive: true,
            windowCount: 3)
        let screenFrame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 2000, height: 1200)
        let visibleOrigin = CGPoint(x: screenFrame.minX + 20, y: screenFrame.minY + 20)
        let offscreenOrigin = CGPoint(x: screenFrame.maxX + 10000, y: screenFrame.maxY + 10000)

        return try LinkedApplicationInventoryGraph(nodes: [
            .init(application: app, windows: [
                ServiceWindowInfo(
                    windowID: 100,
                    title: "",
                    bounds: CGRect(origin: offscreenOrigin, size: CGSize(width: 2560, height: 30)),
                    index: 0,
                    isOnScreen: false),
                ServiceWindowInfo(
                    windowID: 41,
                    title: "Small Utility",
                    bounds: CGRect(origin: visibleOrigin, size: CGSize(width: 120, height: 90)),
                    index: 1),
                ServiceWindowInfo(
                    windowID: 42,
                    title: "Zephyr Agency",
                    bounds: CGRect(origin: visibleOrigin, size: CGSize(width: 1460, height: 945)),
                    index: 2),
            ]),
        ])
    }

    private static func captureMetadata(
        application: ServiceApplicationInfo,
        windows: [ServiceWindowInfo]) -> [CGWindowID: CaptureMetadata]
    {
        Dictionary(uniqueKeysWithValues: windows.map { window in
            (CGWindowID(window.windowID), CaptureMetadata(
                size: window.bounds.size,
                mode: .window,
                applicationInfo: application,
                windowInfo: window))
        })
    }

    private static func observationSpanNames(from response: ToolResponse) -> [String] {
        guard case let .object(meta) = response.meta,
              case let .object(observation)? = meta["observation"],
              case let .object(timings)? = observation["timings"],
              case let .array(spans)? = timings["spans"]
        else {
            return []
        }

        return spans.compactMap { span in
            guard case let .object(spanPayload) = span,
                  case let .string(name)? = spanPayload["name"]
            else {
                return nil
            }
            return name
        }
    }

    private static func coordinateContext(from response: ToolResponse) -> [String: Value]? {
        guard case let .object(meta) = response.meta,
              case let .object(context)? = meta["coordinate_context"]
        else {
            return nil
        }
        return context
    }

    private static func double(from value: Value?) -> Double? {
        switch value {
        case let .double(number): number
        case let .int(number): Double(number)
        default: nil
        }
    }

    private static func size(from value: Value?) -> CGSize? {
        guard case let .object(size)? = value,
              let width = self.double(from: size["width"]),
              let height = self.double(from: size["height"])
        else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    private static func rect(from value: Value?) -> CGRect? {
        guard case let .object(rect)? = value,
              let x = self.double(from: rect["x"]),
              let y = self.double(from: rect["y"]),
              let width = self.double(from: rect["width"]),
              let height = self.double(from: rect["height"])
        else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func makePNGData(width: Int, height: Int) -> Data {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            fatalError("Failed to generate test image")
        }

        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            fatalError("Failed to generate test image")
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil)
        else {
            fatalError("Failed to create test PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            fatalError("Failed to encode test PNG")
        }
        return data as Data
    }

    private static func imageDimensions(from data: Data) -> CGSize? {
        guard let rep = NSBitmapImageRep(data: data) else {
            return nil
        }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}

@Suite(.serialized) struct MCPElementActionToolExecutionTests {
    @Test
    func `element action tools refuse without an active snapshot before automation dispatch`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run { MockElementActionAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)

        let actionResponse = try await ActionTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "B1",
            "action": "AXPress",
        ]))
        let setValueResponse = try await SetValueTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "T1",
            "value": "hello",
        ]))

        for response in [actionResponse, setValueResponse] {
            #expect(response.isError)
            guard case let .object(meta) = response.meta else {
                Issue.record("Expected typed pre-dispatch metadata")
                continue
            }
            #expect(meta["effect"] == .string("refused"))
            #expect(meta["error_code"] == .string("SNAPSHOT_NOT_FOUND"))
            #expect(meta["mutation_dispatched"] == .bool(false))
            #expect(meta["retry_safe"] == .bool(true))
        }
        #expect(await MainActor.run { automation.performActionCalls.isEmpty })
        #expect(await MainActor.run { automation.setValueCalls.isEmpty })
    }

    @Test
    func `set_value tool calls element action service`() async throws {
        let automation = await MainActor.run { MockElementActionAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let tool = SetValueTool(context: context)
        let snapshot = await MCPToolTestHelpers.createElementActionSnapshot(in: context.uiSnapshots)
        let snapshotId = await snapshot.id

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "on": "T1",
            "value": "hello",
            "snapshot": snapshotId,
        ]))

        #expect(response.isError == false)
        let call = await MainActor.run { automation.setValueCalls.first }
        #expect(call?.target == "T1")
        #expect(call?.value == .string("hello"))
        #expect(call?.snapshotId == snapshotId)
        let preserved = await UISnapshotManager.shared.getSnapshot(id: snapshotId)
        let implicitLatest = await UISnapshotManager.shared.getSnapshot(id: nil)
        let implicitLatestID = await implicitLatest?.id
        #expect(preserved != nil)
        #expect(implicitLatestID == snapshotId)
        #expect(!MCPResponseMeta.requiresFreshObservation(response))
        #expect(!MCPResponseMeta.hasRequiresFreshSee(response))
    }

    @Test
    func `set_value tool forwards latest snapshot id when snapshot argument is omitted`() async throws {
        let automation = await MainActor.run { MockElementActionAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let tool = SetValueTool(context: context)
        let snapshot = await MCPToolTestHelpers.createElementActionSnapshot(in: context.uiSnapshots)
        let snapshotId = await snapshot.id

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "on": "T1",
            "value": "hello",
        ]))

        #expect(response.isError == false)
        let call = await MainActor.run { automation.setValueCalls.first }
        #expect(call?.snapshotId == snapshotId)
        let preserved = await UISnapshotManager.shared.getSnapshot(id: snapshotId)
        let implicitLatest = await UISnapshotManager.shared.getSnapshot(id: nil)
        let implicitLatestID = await implicitLatest?.id
        #expect(preserved != nil)
        #expect(implicitLatestID == snapshotId)
        #expect(!MCPResponseMeta.requiresFreshObservation(response))
        #expect(!MCPResponseMeta.hasRequiresFreshSee(response))
    }

    @Test
    func `set_value tool preserves post-dispatch readback failure and exact retry guidance`() async throws {
        let automation = await MainActor.run { MockElementActionAutomationService(accessibilityGranted: true) }
        let receipt = DesktopActionTargetReceipt(
            processIdentifier: 42,
            processStartIdentity: 9,
            windowID: 73)
        await MainActor.run {
            automation.uiAutomationOutcomeScript.appendFailure(
                DesktopActionFailure.indeterminate(
                    delivery: .init(mechanism: .accessibilityValue, mode: .background),
                    evidence: .completionUnknown,
                    unitCount: .one,
                    message: "The submitted value could not be read back.",
                    hint: "Observe the exact target before retrying.")
                    .attributed(to: receipt),
                for: .setValue)
        }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await MCPToolTestHelpers.createElementActionSnapshot(in: context.uiSnapshots)
        let snapshotID = await snapshot.id

        let response = try await SetValueTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "T1",
            "value": "hello",
            "snapshot": snapshotID,
        ]))

        let meta = try #require(response.meta?.objectValue)
        let target = try #require(meta["target_receipt"]?.objectValue)
        #expect(response.isError)
        #expect(meta["state"] == .string("indeterminate"))
        #expect(meta["delivery_mechanism"] == .string("accessibility_value"))
        #expect(meta["delivery_mode"] == .string("background"))
        #expect(meta["dispatch_state"] == .string("may_have_dispatched"))
        #expect(meta["dispatched_unit_count"] == .int(1))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["requires_fresh_observation"] == .bool(true))
        #expect(meta["invalidated_snapshot"] == .string(snapshotID))
        #expect(target["pid"] == .int(Int(receipt.processIdentifier)))
        #expect(target["process_start_identity_decimal"] == .string("9"))
        #expect(target["window_id"] == .int(73))
        #expect(await UISnapshotManager.shared.getSnapshot(id: nil) == nil)
        #expect(await MainActor.run { automation.setValueCalls.isEmpty })
    }

    @Test
    func `action tool validates request shape`() async throws {
        let automation = await MainActor.run { MockElementActionAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let tool = ActionTool(context: context)
        let snapshot = await MCPToolTestHelpers.createElementActionSnapshot(in: context.uiSnapshots)
        let snapshotId = await snapshot.id

        let missing = try await tool.execute(arguments: ToolArguments(raw: ["on": "B1"]))
        #expect(missing.isError == true)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "on": "B1",
            "action": "AXPress",
            "snapshot": snapshotId,
        ]))

        #expect(response.isError == false)
        let call = await MainActor.run { automation.performActionCalls.first }
        #expect(call?.target == "B1")
        #expect(call?.actionName == "AXPress")
        #expect(call?.snapshotId == snapshotId)
        let preserved = await UISnapshotManager.shared.getSnapshot(id: snapshotId)
        let implicitLatest = await UISnapshotManager.shared.getSnapshot(id: nil)
        let implicitLatestID = await implicitLatest?.id
        #expect(preserved != nil)
        #expect(implicitLatestID == snapshotId)
        #expect(!MCPResponseMeta.requiresFreshObservation(response))
        #expect(!MCPResponseMeta.hasRequiresFreshSee(response))
    }
}

// MARK: - Test Helpers

enum MCPResponseMeta {
    static func requiresFreshObservation(_ response: ToolResponse) -> Bool {
        guard case let .object(meta) = response.meta,
              case .bool(true)? = meta["requires_fresh_observation"]
        else {
            return false
        }
        return true
    }

    static func hasRequiresFreshSee(_ response: ToolResponse) -> Bool {
        guard case let .object(meta) = response.meta else { return false }
        return meta["requires_fresh_see"] != nil
    }
}

// MARK: - Mock Services

final class PointerPolicyWindowService: WindowManagementServiceProtocol, @unchecked Sendable {
    let window: ServiceWindowInfo

    init(window: ServiceWindowInfo) {
        self.window = window
    }

    func closeWindow(target _: WindowTarget) async throws {}
    func minimizeWindow(target _: WindowTarget) async throws {}
    func maximizeWindow(target _: WindowTarget) async throws {}
    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {}
    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {}
    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {}
    func focusWindow(target _: WindowTarget) async throws {}

    func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo] {
        if case let .windowId(windowID) = target, windowID == self.window.windowID {
            return [self.window]
        }
        return []
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        self.window
    }
}

actor EmptyRecordingWindowService: WindowManagementServiceProtocol, WindowMutationInventoryProviding {
    private(set) var requestedWindowIDs: [Int] = []
    private(set) var focusRequests: [WindowTarget] = []

    func closeWindow(target _: WindowTarget) async throws {}
    func minimizeWindow(target _: WindowTarget) async throws {}
    func maximizeWindow(target _: WindowTarget) async throws {}
    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {}
    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {}
    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {}
    func focusWindow(target: WindowTarget) async throws {
        self.focusRequests.append(target)
    }

    func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo] {
        if case let .windowId(windowID) = target {
            self.requestedWindowIDs.append(windowID)
        }
        return []
    }

    func windowMutationInventory(
        target _: WindowTarget) async throws -> DesktopTargetPlanning.Inventory<ServiceWindowInfo>
    {
        .complete([])
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }
}

@MainActor
class MockAutomationService: ExactWindowTargetedClickServiceProtocol, TargetedHotkeyServiceProtocol,
    TargetedTypeServiceProtocol, ExactWindowPixelFocusTypingServiceProtocol, ForegroundModifierClickServiceProtocol,
    CompositeTypeDeliveryServiceProtocol
{
    struct ClickCall {
        let target: ClickTarget
        let clickType: ClickType
        let snapshotId: String?
    }

    struct TargetedClickCall {
        let target: ClickTarget
        let clickType: ClickType
        let snapshotId: String?
        let targetProcessIdentifier: pid_t
        let targetWindowID: Int?
        let expectedProcessIdentity: ApplicationProcessIdentity?
    }

    struct TargetedHotkeyCall {
        let keys: String
        let holdDuration: Int
        let targetProcessIdentifier: pid_t
        let expectedProcessIdentity: ApplicationProcessIdentity?
    }

    struct TargetedTypeActionsCall {
        let actions: [TypeAction]
        let cadence: TypingCadence
        let snapshotId: String?
        let targetProcessIdentifier: pid_t
        let expectedProcessIdentity: ApplicationProcessIdentity?
    }

    var supportsExactWindowCompositeTypeDelivery = true
    let exactWindowCompositeTypeDeliveryUnavailableReason: String? = nil

    private let accessibilityGranted: Bool
    private let detectionResult: ElementDetectionResult?
    private let detectionError: (any Error)?
    private let mockCurrentMouseLocation: CGPoint?
    private(set) var clickCalls: [ClickCall] = []
    var targetedClickCalls: [TargetedClickCall] = []
    var targetedHotkeyCalls: [TargetedHotkeyCall] = []
    var targetedTypeActionsCalls: [TargetedTypeActionsCall] = []
    private(set) var scrollRequests: [ScrollRequest] = []
    private(set) var lastTypeActions: [TypeAction]?
    private(set) var lastTypeSnapshotId: String?
    var lastCadence: TypingCadence?
    private(set) var lastHotkeyKeys: String?
    private(set) var lastHotkeyHoldDuration: Int?
    private(set) var lastMoveTarget: CGPoint?
    private(set) var lastMoveDuration: Int?
    private(set) var lastWindowContext: WindowContext?
    var supportsTargetedHotkeys = true
    var supportsProcessGenerationPinnedHotkeys = true
    var currentProcessIdentity: ((pid_t) -> ApplicationProcessIdentity?)?
    var afterPinnedHotkey: (() -> Void)?
    var pinnedHotkeyError: ((String) -> (any Error)?)?
    var targetedHotkeyUnavailableReason: String?
    var targetedHotkeyRequiresEventSynthesizingPermission = false
    var supportsTargetedTypeActions = true
    var supportsProcessGenerationPinnedTypeActions = true
    var targetedTypeUnavailableReason: String?
    var targetedTypeRequiresEventSynthesizingPermission = false
    var supportsProcessGenerationPinnedClicks = true
    var supportsStatelessClickVariants = true
    var pinnedClickError: ((ClickTarget) -> (any Error)?)?
    var pinnedTypeError: (([TypeAction]) -> (any Error)?)?
    var supportsExactWindowPixelFocusTyping = true
    var exactWindowPixelFocusTypingUnavailableReason: String?
    var supportsForegroundModifierClick = true
    var supportsForegroundModifierClickSnapshotLease = true
    var foregroundModifierClickUnavailableReason: String?
    var foregroundModifierClickRefusalReason: DesktopActionOutcome.RefusalReason?
    var foregroundModifierClickError: (any Error)?
    private(set) var pixelFocusTypeRequests: [ExactWindowPixelFocusTypeRequest] = []
    private(set) var foregroundModifierClickRequests: [ForegroundModifierClickRequest] = []

    init(
        accessibilityGranted: Bool,
        detectionResult: ElementDetectionResult? = nil,
        detectionError: (any Error)? = nil,
        currentMouseLocation: CGPoint? = nil)
    {
        self.accessibilityGranted = accessibilityGranted
        self.detectionResult = detectionResult
        self.detectionError = detectionError
        self.mockCurrentMouseLocation = currentMouseLocation
    }

    func detectElements(in _: Data, snapshotId _: String?, windowContext: WindowContext?) async throws
        -> ElementDetectionResult
    {
        self.lastWindowContext = windowContext
        if let detectionError {
            throw detectionError
        }
        if let detectionResult = self.detectionResult {
            return detectionResult
        }
        throw PeekabooError.notImplemented("mock detectElements")
    }

    func inspectAccessibilityTree(windowContext: WindowContext?) async throws -> ElementDetectionResult {
        self.lastWindowContext = windowContext
        if let detectionResult = self.detectionResult {
            return detectionResult
        }
        throw PeekabooError.notImplemented("mock inspectAccessibilityTree")
    }

    func click(target: ClickTarget, clickType: ClickType, snapshotId: String?) async throws {
        self.clickCalls.append(ClickCall(target: target, clickType: clickType, snapshotId: snapshotId))
    }

    func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t) async throws
    {
        self.targetedClickCalls.append(TargetedClickCall(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            targetProcessIdentifier: targetProcessIdentifier,
            targetWindowID: nil,
            expectedProcessIdentity: nil))
    }

    func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds _: CGRect) async throws
    {
        self.targetedClickCalls.append(TargetedClickCall(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            targetProcessIdentifier: expectedWindowIdentity.ownerProcessIdentifier,
            targetWindowID: expectedWindowIdentity.windowID,
            expectedProcessIdentity: ApplicationProcessIdentity(
                processIdentifier: expectedWindowIdentity.ownerProcessIdentifier,
                processStartIdentity: expectedWindowIdentity.ownerProcessStartIdentity)))
    }

    func type(text _: String, target _: String?, clearExisting _: Bool, typingDelay _: Int, snapshotId _: String?) async
    throws {}

    func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?) async throws -> TypeResult
    {
        self.lastTypeActions = actions
        self.lastCadence = cadence
        self.lastTypeSnapshotId = snapshotId
        return TypeResult(totalCharacters: 0, keyPresses: 0)
    }

    func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        targetProcessIdentifier: pid_t) async throws -> TypeResult
    {
        self.targetedTypeActionsCalls.append(TargetedTypeActionsCall(
            actions: actions,
            cadence: cadence,
            snapshotId: snapshotId,
            targetProcessIdentifier: targetProcessIdentifier,
            expectedProcessIdentity: nil))
        return try await self.typeActions(actions, cadence: cadence, snapshotId: snapshotId)
    }

    func typeActionsByFocusingPixelWithOutcome(
        _ request: ExactWindowPixelFocusTypeRequest) async throws -> UIAutomationActionResult<TypeResult>
    {
        self.pixelFocusTypeRequests.append(request)
        let result = Self.typeResult(for: request.actions)
        return try UIAutomationActionResult(
            payload: result,
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .composite, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .init(result.keyPresses + 1)),
            targetIdentity: DesktopTargetIdentity(exactWindow: .init(
                identity: request.windowIdentity,
                bounds: request.windowBounds)))
    }

    func foregroundModifierClickWithOutcome(
        _ request: ForegroundModifierClickRequest) async throws
        -> UIAutomationActionResult<ForegroundModifierClickResult>
    {
        if let foregroundModifierClickError {
            throw foregroundModifierClickError
        }
        self.foregroundModifierClickRequests.append(request)
        let outcome: DesktopActionOutcome = if let foregroundModifierClickRefusalReason {
            .refused(reason: foregroundModifierClickRefusalReason)
        } else {
            .dispatchedUnverified(
                delivery: .init(mechanism: .composite, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one)
        }
        return try UIAutomationActionResult(
            payload: .init(cursorRestoration: .restored, focusRestoration: .preservedNewerState),
            outcome: outcome,
            targetIdentity: DesktopTargetIdentity(exactWindow: .init(
                identity: request.windowIdentity,
                bounds: request.windowBounds)))
    }

    func scroll(_ request: ScrollRequest) async throws {
        self.scrollRequests.append(request)
    }

    func hotkey(keys: String, holdDuration: Int) async throws {
        self.lastHotkeyKeys = keys
        self.lastHotkeyHoldDuration = holdDuration
    }

    func hotkey(keys: String, holdDuration: Int, targetProcessIdentifier: pid_t) async throws {
        self.targetedHotkeyCalls.append(TargetedHotkeyCall(
            keys: keys,
            holdDuration: holdDuration,
            targetProcessIdentifier: targetProcessIdentifier,
            expectedProcessIdentity: nil))
    }

    func swipe(
        from _: CGPoint,
        to _: CGPoint,
        duration _: Int,
        steps _: Int,
        profile _: MouseMovementProfile) async throws {}

    func hasAccessibilityPermission() async -> Bool {
        self.accessibilityGranted
    }

    func waitForElement(target _: ClickTarget, timeout _: TimeInterval, snapshotId _: String?) async throws
        -> WaitForElementResult
    {
        WaitForElementResult(found: false, element: nil, waitTime: 0)
    }

    func drag(_: DragOperationRequest) async throws {}

    func moveMouse(
        to: CGPoint,
        duration: Int,
        steps _: Int,
        profile _: MouseMovementProfile) async throws
    {
        self.lastMoveTarget = to
        self.lastMoveDuration = duration
    }

    func currentMouseLocation() -> CGPoint? {
        self.mockCurrentMouseLocation
    }

    func getFocusedElement() -> UIFocusInfo? {
        nil
    }

    func findElement(matching _: UIElementSearchCriteria, in _: String?) async throws -> DetectedElement {
        throw PeekabooError.elementNotFound("mock find element")
    }

    private static func typeResult(for actions: [TypeAction]) -> TypeResult {
        var characters = 0
        var keyPresses = 0
        var specialKeyPresses = 0
        for action in actions {
            switch action {
            case let .text(text):
                characters += text.count
                keyPresses += text.count
            case .key:
                keyPresses += 1
                specialKeyPresses += 1
            case .clear:
                keyPresses += 2
                specialKeyPresses += 2
            }
        }
        return TypeResult(
            totalCharacters: characters,
            keyPresses: keyPresses,
            specialKeyPresses: specialKeyPresses)
    }
}

@MainActor
final class MockConfirmedTypeAutomationService: MockAutomationService,
ScriptedUIAutomationActionOutcomeProviding {
    let uiAutomationOutcomeScript = UIAutomationOutcomeScript(defaultResponse: .outcome(.confirmedChange(
        delivery: .init(mechanism: .globalEvents, mode: .foreground))))
}

@MainActor
private final class MockElementActionAutomationService: MockAutomationService, ElementActionAutomationServiceProtocol,
ScriptedUIAutomationActionOutcomeProviding {
    let supportsSetValueResultTargetBinding = true
    let supportsProcessGenerationBoundElementMutations = true
    let uiAutomationOutcomeTargetIdentity = try? DesktopTargetIdentity(
        processIdentity: .init(processIdentifier: 42, processStartIdentity: 1001))
    struct SetValueCall {
        let target: String
        let value: UIElementValue
        let snapshotId: String?
    }

    struct PerformActionCall {
        let target: String
        let actionName: String
        let snapshotId: String?
    }

    private(set) var setValueCalls: [SetValueCall] = []
    private(set) var performActionCalls: [PerformActionCall] = []
    let uiAutomationOutcomeScript = UIAutomationOutcomeScript(
        defaultResponse: .outcome(.confirmedNoChange()))

    func setValue(target: String, value: UIElementValue, snapshotId: String?) async throws -> ElementActionResult {
        self.setValueCalls.append(SetValueCall(target: target, value: value, snapshotId: snapshotId))
        return ElementActionResult(
            target: target,
            actionName: "AXSetValue",
            anchorPoint: CGPoint(x: 10, y: 20),
            oldValue: nil,
            newValue: value.displayString)
    }

    func performAction(target: String, actionName: String, snapshotId: String?) async throws -> ElementActionResult {
        self.performActionCalls.append(PerformActionCall(
            target: target,
            actionName: actionName,
            snapshotId: snapshotId))
        return ElementActionResult(target: target, actionName: actionName, anchorPoint: CGPoint(x: 10, y: 20))
    }
}

@MainActor
final class MockScreenCaptureService: ScreenCaptureServiceProtocol {
    private let screenRecordingGranted: Bool
    private let imageData: Data
    private let metadata: CaptureMetadata?
    private let windowMetadata: [CGWindowID: CaptureMetadata]
    private(set) var captureAttemptCount = 0
    private(set) var lastWindowID: CGWindowID?
    private(set) var lastAppIdentifier: String?
    private(set) var lastArea: CGRect?
    private(set) var lastScale: CaptureScalePreference?

    init(screenRecordingGranted: Bool) {
        self.screenRecordingGranted = screenRecordingGranted
        self.imageData = Self.validPNGData
        self.metadata = nil
        self.windowMetadata = [:]
    }

    init(screenRecordingGranted: Bool, metadata: CaptureMetadata) {
        self.screenRecordingGranted = screenRecordingGranted
        self.imageData = Self.validPNGData
        self.metadata = metadata
        self.windowMetadata = [:]
    }

    init(screenRecordingGranted: Bool, imageData: Data, metadata: CaptureMetadata? = nil) {
        self.screenRecordingGranted = screenRecordingGranted
        self.imageData = imageData
        self.metadata = metadata
        self.windowMetadata = [:]
    }

    init(screenRecordingGranted: Bool, windowMetadata: [CGWindowID: CaptureMetadata]) {
        self.screenRecordingGranted = screenRecordingGranted
        self.imageData = Self.validPNGData
        self.metadata = nil
        self.windowMetadata = windowMetadata
    }

    func captureScreen(
        displayIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        self.captureAttemptCount += 1
        self.lastScale = scale
        return self.makeResult(mode: .screen)
    }

    func captureWindow(
        appIdentifier: String,
        windowIndex: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        self.captureAttemptCount += 1
        self.lastAppIdentifier = appIdentifier
        self.lastScale = scale
        return self.makeResult(
            mode: .window,
            window: ServiceWindowInfo(
                windowID: windowIndex ?? 0,
                title: appIdentifier,
                bounds: .zero,
                index: windowIndex ?? 0))
    }

    func captureWindow(
        windowID: CGWindowID,
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        self.captureAttemptCount += 1
        self.lastWindowID = windowID
        self.lastScale = scale
        if let metadata = self.windowMetadata[windowID] {
            return CaptureResult(imageData: self.imageData, metadata: metadata)
        }
        return self.makeResult(
            mode: .window,
            window: ServiceWindowInfo(
                windowID: Int(windowID),
                title: "Window \(windowID)",
                bounds: .zero,
                index: Int(windowID)))
    }

    func captureFrontmost(
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        self.captureAttemptCount += 1
        self.lastScale = scale
        return self.makeResult(mode: .frontmost)
    }

    func captureArea(
        _ rect: CGRect,
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        self.captureAttemptCount += 1
        self.lastArea = rect
        self.lastScale = scale
        return self.makeResult(mode: .area)
    }

    func hasScreenRecordingPermission() async -> Bool {
        self.screenRecordingGranted
    }

    private func makeResult(mode: CaptureMode, window: ServiceWindowInfo? = nil) -> CaptureResult {
        CaptureResult(
            imageData: self.imageData,
            metadata: self.metadata ?? CaptureMetadata(size: .zero, mode: mode, windowInfo: window))
    }

    private static let validPNGData = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
        0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
        0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D,
        0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82,
    ])
}

@MainActor
final class MockScreenService: ScreenServiceProtocol {
    private let screens: [ScreenInfo]

    init(screens: [ScreenInfo]) {
        self.screens = screens
    }

    func listScreens() -> [ScreenInfo] {
        self.screens
    }

    func screenContainingWindow(bounds: CGRect) -> ScreenInfo? {
        self.screens.first { $0.frame.intersects(bounds) }
    }

    func screen(at index: Int) -> ScreenInfo? {
        self.screens.first { $0.index == index }
    }

    var primaryScreen: ScreenInfo? {
        self.screens.first { $0.isPrimary } ?? self.screens.first
    }
}

@MainActor
class MockApplicationService: ScriptedApplicationInventoryService {
    override func getFrontmostApplication() async throws -> ServiceApplicationInfo {
        self.applications.first ?? ServiceApplicationInfo(
            processIdentifier: 0,
            bundleIdentifier: nil,
            name: "Mock")
    }

    override func activateApplication(identifier _: String) async throws {}
    override func activateApplication(request _: ApplicationActivationRequest) async throws {}

    override func quitApplication(identifier _: String, force _: Bool) async throws -> Bool {
        true
    }

    override func quitApplication(request: ApplicationQuitRequest) async throws -> Bool {
        guard request.expectedIdentity == nil else {
            throw PeekabooError.serviceUnavailable(
                "This application service does not support process-generation-pinned quit; update the runtime host")
        }
        return try await self.quitApplication(identifier: request.identifier, force: request.force)
    }
}

struct MCPToolErrorHandlingTests {
    @Test
    func `Tool handles invalid argument types gracefully`() async throws {
        let automation = await MainActor.run { MockConfirmedTypeAutomationService(accessibilityGranted: true) }

        try await MCPToolTestHelpers.withContext(automation: automation) {
            let tool = TypeTool()

            // Pass number where string expected
            let args = ToolArguments(raw: ["text": 12345, "foreground": true])

            let response = try await tool.execute(arguments: args)

            // Tool should either convert or error gracefully
            // TypeTool should convert number to string
            #expect(response.isError == false)
        }

        let capturedActions = await MainActor.run { automation.lastTypeActions }
        guard case let .text(value)? = capturedActions?.first else {
            Issue.record("Expected TypeTool to call the injected mock with converted text.")
            return
        }
        #expect(value == "12345")
    }

    @Test
    func `Tool handles missing required arguments`() async throws {
        try await MCPToolTestHelpers.withContext {
            let tool = ClickTool()

            // ClickTool actually has no required parameters - it will error if no valid input is provided
            let args = ToolArguments(raw: [:])

            let response = try await tool.execute(arguments: args)
            #expect(response.isError == true)

            if case let .text(text: error, annotations: _, _meta: _) = response.content.first {
                // Should mention that it needs some input like query, on, or coords
                #expect(error.lowercased().contains("specify") || error.lowercased().contains("provide") || error
                    .lowercased().contains("must"))
            }
        }
    }

    @Test
    func `Tool handles malformed coordinate strings`() async throws {
        try await MCPToolTestHelpers.withContext {
            let tool = ClickTool()
            let args = ToolArguments(raw: ["coords": "not-a-coordinate"])
            let response = try await tool.execute(arguments: args)

            #expect(response.isError == true)

            if case let .text(text: error, annotations: _, _meta: _) = response.content.first {
                #expect(error.contains("Invalid coordinates format") || error.contains("coordinates"))
            }
        }
    }

    @Test
    func `Window tool reports missing target as validation error`() async throws {
        let context = await MCPToolTestHelpers.makeContext(executionPolicy: .foregroundAllowed)
        let tool = WindowTool(context: context)

        let response = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "focus"]))

        #expect(response.isError == true)

        guard case let .text(text: error, annotations: _, _meta: _) = response.content.first else {
            Issue.record("Expected text error response")
            return
        }

        #expect(error.contains("Must specify at least 'window_id', 'app', or 'title'"))
        #expect(!error.contains("Failed to focus window"))
    }

    @Test
    func `Type tool defaults to linear cadence`() async throws {
        let automation = await MainActor.run { MockConfirmedTypeAutomationService(accessibilityGranted: true) }

        try await MCPToolTestHelpers.withContext(automation: automation) {
            let tool = TypeTool()
            let response = try await tool.execute(arguments: ToolArguments(raw: [
                "text": "Hello",
                "foreground": true,
            ]))
            #expect(response.isError == false)
        }

        let capturedCadence = await MainActor.run { automation.lastCadence }
        guard let cadence = capturedCadence else {
            Issue.record("Expected automation service to capture cadence")
            return
        }

        if case let .fixed(milliseconds) = cadence {
            #expect(milliseconds == 0)
        } else {
            Issue.record("Expected linear cadence, got \(cadence)")
        }
    }

    @Test
    func `Type tool describes clear-only requests without claiming it typed`() async throws {
        let automation = await MainActor.run { MockConfirmedTypeAutomationService(accessibilityGranted: true) }

        try await MCPToolTestHelpers.withContext(automation: automation) {
            let response = try await TypeTool().execute(arguments: ToolArguments(raw: [
                "clear": true,
                "foreground": true,
            ]))

            #expect(response.isError == false)
            guard case let .object(meta) = response.meta,
                  case let .object(summary)? = meta["summary"],
                  case let .string(action)? = summary["action"]
            else {
                Issue.record("Expected type response summary action")
                return
            }
            #expect(action == "Clear Field")
        }
    }

    @Test
    func `Type tool with WPM opts into human cadence`() async throws {
        let automation = await MainActor.run { MockConfirmedTypeAutomationService(accessibilityGranted: true) }

        try await MCPToolTestHelpers.withContext(automation: automation) {
            let tool = TypeTool()
            let response = try await tool.execute(arguments: ToolArguments(raw: [
                "text": "Hello",
                "wpm": 140,
                "foreground": true,
            ]))
            #expect(response.isError == false)
        }

        let capturedCadence = await MainActor.run { automation.lastCadence }
        guard let cadence = capturedCadence else {
            Issue.record("Expected automation service to capture cadence")
            return
        }

        if case let .human(wordsPerMinute) = cadence {
            #expect(wordsPerMinute == 140)
        } else {
            Issue.record("Expected human cadence, got \(cadence)")
        }
    }

    @Test
    func `Type tool honors linear profile`() async throws {
        let automation = await MainActor.run { MockConfirmedTypeAutomationService(accessibilityGranted: true) }

        try await MCPToolTestHelpers.withContext(automation: automation) {
            let tool = TypeTool()
            let response = try await tool.execute(arguments: ToolArguments(raw: [
                "text": "Ping",
                "profile": "linear",
                "delay": 25,
                "foreground": true,
            ]))
            #expect(response.isError == false)
        }

        let capturedCadence = await MainActor.run { automation.lastCadence }
        guard let cadence = capturedCadence else {
            Issue.record("Expected automation service to capture cadence")
            return
        }

        if case let .fixed(milliseconds) = cadence {
            #expect(milliseconds == 25)
        } else {
            Issue.record("Expected linear cadence, got \(cadence)")
        }
    }
}

@Suite(.tags(.integration))
struct MCPToolIntegrationTests {
    @Test
    func `Multiple tools can execute concurrently`() async throws {
        let apps = [ServiceApplicationInfo(processIdentifier: 1, bundleIdentifier: "com.test.app", name: "TestApp")]
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let screenCapture = await MainActor.run { MockScreenCaptureService(screenRecordingGranted: true) }
        let appService = await MainActor.run { MockApplicationService(applications: apps) }
        try await MCPToolTestHelpers.withContext(
            automation: automation,
            screenCapture: screenCapture,
            applications: appService)
        {
            let sleepTool = SleepTool()
            let permissionsTool = PermissionsTool()
            let appTool = AppTool()

            async let sleep = sleepTool.execute(arguments: ToolArguments(raw: ["duration": 1]))
            async let permissions = permissionsTool.execute(arguments: ToolArguments(raw: [:]))
            async let list = appTool.execute(arguments: ToolArguments(raw: ["action": "list"]))

            let results = try await (sleep, permissions, list)

            #expect(results.0.isError == false)
            #expect(results.1.isError == false)
            #expect(results.2.isError == false)
        }
    }

    @Test
    func `Tool execution with complex arguments`() async throws {
        // Test tools that accept complex nested arguments
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let screenCapture = await MainActor.run { MockScreenCaptureService(screenRecordingGranted: true) }
        try await MCPToolTestHelpers.withContext(automation: automation, screenCapture: screenCapture) {
            let tool = SeeTool()

            let args = ToolArguments(raw: [
                "annotate": true,
                "element_types": ["button", "link", "textfield"],
                "app_target": "Safari:0",
                "output_path": "/tmp/test-annotated.png",
            ])

            let response = try await tool.execute(arguments: args)

            // Can't guarantee Safari is running, but we can verify the tool handles arguments
            if response.isError {
                if case let .text(text: error, annotations: _, _meta: _) = response.content.first {
                    #expect(!error.isEmpty)
                }
            }
        }
    }
}
