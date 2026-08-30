import AppKit
import MCP
import PeekabooAutomationKit
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@Suite(.serialized)
struct MCPSeeExactWindowTests {
    @Test
    func `See tool exact window id is owner validated without changing legacy index syntax`() async throws {
        let (app, windows) = await MainActor.run { Self.makeWindowedTestApp() }
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot-exact-window",
            screenshotPath: "/tmp/peekaboo-see-exact-window-test.png",
            elements: DetectedElements(buttons: [DetectedElement(
                id: "B1",
                type: .button,
                label: "Fixture",
                bounds: CGRect(x: 30, y: 30, width: 80, height: 32))]),
            metadata: DetectionMetadata(detectionTime: 0.01, elementCount: 1, method: "mock"))
        let automation = await MainActor.run {
            MockAutomationService(accessibilityGranted: true, detectionResult: detectionResult)
        }
        let foreignApp = ServiceApplicationInfo(
            processIdentifier: 5678,
            bundleIdentifier: "com.test.foreign",
            name: "Foreign App",
            windowCount: 1)
        let foreignWindow = ServiceWindowInfo(
            windowID: 99999,
            title: "Foreign Window",
            bounds: CGRect(x: 20, y: 20, width: 600, height: 400))
        let applications = await MainActor.run {
            MockApplicationService(applications: [app, foreignApp], windowsByIdentifier: [
                app.bundleIdentifier ?? app.name: windows,
                foreignApp.bundleIdentifier ?? foreignApp.name: [foreignWindow],
            ])
        }
        let screenCapture = await MainActor.run {
            MockScreenCaptureService(
                screenRecordingGranted: true,
                windowMetadata: Dictionary(uniqueKeysWithValues: windows.dropFirst().map { window in
                    (CGWindowID(window.windowID), CaptureMetadata(
                        size: window.bounds.size,
                        mode: .window,
                        applicationInfo: app,
                        windowInfo: window))
                }))
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            screenCapture: screenCapture,
            applications: applications,
            exactWindowMetadataProvider: ExactWindowTestMetadataProvider(values: [
                42: ExactWindowObservationMetadata(
                    ownerProcessIdentifier: app.processIdentifier,
                    ownerProcessStartIdentity: 700,
                    title: "Zephyr Agency",
                    bounds: windows[2].bounds),
                99999: ExactWindowObservationMetadata(
                    ownerProcessIdentifier: foreignApp.processIdentifier,
                    ownerProcessStartIdentity: 700,
                    title: foreignWindow.title,
                    bounds: foreignWindow.bounds),
            ]))
        let tool = SeeTool(context: context)

        let legacyIndex = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "app_target": "\(app.name):1",
            ]))
        #expect(legacyIndex.isError == false)
        #expect(await MainActor.run { screenCapture.lastWindowID } == 41)

        let exact = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "app_target": app.name,
                "window_id": 42,
            ]))
        #expect(exact.isError == false)
        #expect(await MainActor.run { screenCapture.lastWindowID } == 42)

        let mixedSelectors = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "app_target": "\(app.name):1",
                "window_id": 42,
            ]))
        #expect(mixedSelectors.isError)

        let wrongOwner = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "app_target": app.name,
                "window_id": 99999,
            ]))
        #expect(wrongOwner.isError)
        #expect(await MainActor.run { screenCapture.captureAttemptCount } == 2)
    }

    @Test
    func `See tool exact window id requires an owner target`() async throws {
        let screenCapture = await MainActor.run { MockScreenCaptureService(screenRecordingGranted: true) }
        let context = await MCPToolTestHelpers.makeContext(screenCapture: screenCapture)

        let response = try await context.execute(
            tool: SeeTool(context: context),
            arguments: ToolArguments(raw: [
                "window_id": 42,
            ]))

        #expect(response.isError)
        #expect(await MainActor.run { screenCapture.captureAttemptCount } == 0)
    }

    @Test
    func `See tool rejects every supplied invalid window id before capture`() async throws {
        let screenCapture = await MainActor.run { MockScreenCaptureService(screenRecordingGranted: true) }
        let context = await MCPToolTestHelpers.makeContext(screenCapture: screenCapture)
        let tool = SeeTool(context: context)
        let invalidValues: [Any] = [
            "42",
            42.5,
            0,
            -1,
            Int(UInt32.max) + 1,
            true,
            NSNull(),
        ]

        for invalidValue in invalidValues {
            let response = try await context.execute(
                tool: tool,
                arguments: ToolArguments(raw: [
                    "app_target": "Safari",
                    "window_id": invalidValue,
                ]))
            #expect(response.isError, "Expected window_id \(String(describing: invalidValue)) to fail")
        }
        let conflictingSelectors = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "app_target": "Safari:Main",
                "window_id": 42,
            ]))
        #expect(conflictingSelectors.isError)
        #expect(await MainActor.run { screenCapture.captureAttemptCount } == 0)
    }

    @Test
    func `See tool declares window id as a bounded integer`() async {
        let context = await MCPToolTestHelpers.makeContext()
        let tool = SeeTool(context: context)
        guard case let .object(root) = tool.inputSchema,
              case let .object(properties)? = root["properties"],
              case let .object(windowID)? = properties["window_id"]
        else {
            Issue.record("Expected window_id schema")
            return
        }

        #expect(windowID["type"] == .string("integer"))
        #expect(windowID["minimum"] == .int(1))
        #expect(windowID["maximum"] == .int(Int(UInt32.max)))
    }

    @MainActor
    private static func makeWindowedTestApp() -> (ServiceApplicationInfo, [ServiceWindowInfo]) {
        let app = ServiceApplicationInfo(
            processIdentifier: 1234,
            processStartIdentity: 700,
            bundleIdentifier: "com.test.zephyr",
            name: "Zephyr Agency",
            isActive: true,
            windowCount: 3)
        let screenFrame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 2000, height: 1200)
        let visibleOrigin = CGPoint(x: screenFrame.minX + 20, y: screenFrame.minY + 20)
        let offscreenOrigin = CGPoint(x: screenFrame.maxX + 10000, y: screenFrame.maxY + 10000)

        return (app, [
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
                index: 1,
                mutationIdentity: WindowMutationIdentity(
                    windowID: 41,
                    ownerProcessIdentifier: app.processIdentifier,
                    ownerProcessStartIdentity: 700,
                    capturedBounds: CGRect(origin: visibleOrigin, size: CGSize(width: 120, height: 90)))),
            ServiceWindowInfo(
                windowID: 42,
                title: "Zephyr Agency",
                bounds: CGRect(origin: visibleOrigin, size: CGSize(width: 1460, height: 945)),
                index: 2,
                mutationIdentity: WindowMutationIdentity(
                    windowID: 42,
                    ownerProcessIdentifier: app.processIdentifier,
                    ownerProcessStartIdentity: 700,
                    capturedBounds: CGRect(origin: visibleOrigin, size: CGSize(width: 1460, height: 945)))),
        ])
    }
}

private struct ExactWindowTestMetadataProvider: ExactWindowMetadataProviding {
    let values: [CGWindowID: ExactWindowObservationMetadata]

    func metadata(for windowID: CGWindowID) -> ExactWindowObservationMetadata? {
        self.values[windowID]
    }

    func processStartIdentity(for _: Int32) -> UInt64? {
        700
    }
}
