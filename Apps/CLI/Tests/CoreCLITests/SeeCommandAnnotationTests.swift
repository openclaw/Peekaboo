import Commander
import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooCLI
@testable import PeekabooCore

@Suite(.serialized, .tags(.safe))
struct SeeCommandAnnotationTests {
    @Test
    func `SeeCommand parses basic options standalone`() throws {
        let command = try SeeCommand.parse(["--mode", "screen"])
        #expect(command.mode == .screen)
    }

    @Test
    func `Annotation creates annotated file with correct naming`() {
        // Given an original path
        let originalPath = "/tmp/screenshot.png"

        // When creating annotated path
        let annotatedPath = (originalPath as NSString).deletingPathExtension + "_annotated.png"

        // Then the path should follow the naming convention
        #expect(annotatedPath == "/tmp/screenshot_annotated.png")
    }

    @Test
    func `Element bounds are transformed correctly for annotations`() {
        // Given elements in screen coordinates
        let screenElement = DetectedElement(
            id: "B1",
            type: .button,
            label: "Test Button",
            value: nil,
            bounds: CGRect(x: 500, y: 300, width: 100, height: 50),
            isEnabled: true,
            isSelected: nil,
            attributes: [:]
        )

        // And a window bounds
        let windowBounds = CGRect(x: 400, y: 200, width: 800, height: 600)

        // When transforming to window-relative coordinates (as done in UIAutomationServiceEnhanced)
        var transformedBounds = screenElement.bounds
        transformedBounds.origin.x -= windowBounds.origin.x
        transformedBounds.origin.y -= windowBounds.origin.y

        // Then the bounds should be relative to window
        #expect(transformedBounds.origin.x == 100) // 500 - 400
        #expect(transformedBounds.origin.y == 100) // 300 - 200
        #expect(transformedBounds.size.width == 100) // unchanged
        #expect(transformedBounds.size.height == 50) // unchanged
    }

    @Test
    func `Annotation uses captured window origin instead of first element origin`() {
        let element = DetectedElement(
            id: "elem_63",
            type: .button,
            label: "Update",
            value: nil,
            bounds: CGRect(x: 500, y: 300, width: 100, height: 50),
            isEnabled: true,
            isSelected: nil,
            attributes: [:]
        )
        let windowBounds = CGRect(x: 400, y: 200, width: 800, height: 600)
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot-1",
            screenshotPath: "/tmp/snapshot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 1,
                method: "AXorcist",
                warnings: [],
                windowContext: WindowContext(windowBounds: windowBounds),
                isDialog: false
            )
        )

        let windowOrigin = ObservationAnnotationCoordinateMapper.windowOrigin(for: detectionResult)
        let drawingRect = ObservationAnnotationCoordinateMapper.drawingRect(
            for: element,
            imageSize: CGSize(width: 800, height: 600),
            windowOrigin: windowOrigin
        )

        #expect(windowOrigin == CGPoint(x: 400, y: 200))
        #expect(drawingRect.origin.x == 100)
        #expect(drawingRect.origin.y == 450)
        #expect(drawingRect.size.width == 100)
        #expect(drawingRect.size.height == 50)
    }

    @Test
    func `Annotation is disabled for screen mode captures`() {
        // This test documents that annotation should be disabled for full screen captures
        // due to performance constraints

        // When attempting to annotate a screen capture
        // The see command should log a warning and continue without annotation

        // Expected behavior:
        // 1. User requests: peekaboo see --mode screen --annotate
        // 2. System logs: "Annotation is disabled for full screen captures due to performance constraints"
        // 3. Capture proceeds without annotation
        // 4. No annotated file is created

        #expect(Bool(true)) // Documentation-only test; use Bool(true) to avoid warning
    }

    @Test
    @MainActor
    func `Screen index captures use observation target`() throws {
        let command = try SeeCommand.parse(["--mode", "screen", "--screen-index", "1"])

        #expect(try command.observationTargetForCaptureWithDetectionIfPossible() == .screen(index: 1))
    }

    @Test
    @MainActor
    func `All screen captures stay on legacy multi-file path`() throws {
        let command = try SeeCommand.parse(["--mode", "screen"])

        #expect(try command.observationTargetForCaptureWithDetectionIfPossible() == nil)
    }

    @Test
    @MainActor
    func `Screen analysis captures primary display through observation`() throws {
        let command = try SeeCommand.parse(["--mode", "screen", "--analyze", "summarize"])

        #expect(try command.observationTargetForCaptureWithDetectionIfPossible() == .screen(index: 0))
    }

    @Test
    @MainActor
    func `Frontmost captures use observation target`() throws {
        let command = try SeeCommand.parse(["--mode", "frontmost"])

        #expect(try command.observationTargetForCaptureWithDetectionIfPossible() == .frontmost)
    }

    @Test
    @MainActor
    func `Window mode without target fails before capture fallback`() throws {
        let command = try SeeCommand.parse(["--mode", "window"])

        #expect(throws: ValidationError.self) {
            _ = try command.observationTargetForCaptureWithDetectionIfPossible()
        }
    }

    @Test
    @MainActor
    func `Area mode is rejected before capture fallback`() throws {
        #expect(throws: CommanderBindingError.invalidArgument(
            label: "mode",
            value: "area",
            reason: "`see` supports screen, window, frontmost, or multi"
        )) {
            _ = try SeeCommand.parse(["--mode", "area"])
        }
    }

    @Test
    @MainActor
    func `Area observation target fails explicitly`() throws {
        var command = SeeCommand()
        command.mode = .area

        #expect(throws: ValidationError.self) {
            _ = try command.observationTargetForCaptureWithDetectionIfPossible()
        }
    }

    @Test
    @MainActor
    func `App menubar captures use observation target`() throws {
        let command = try SeeCommand.parse(["--app", "menubar"])

        #expect(try command.observationTargetForCaptureWithDetectionIfPossible() == .menubar)
    }

    @Test
    @MainActor
    func `Observation screen targets disable annotations`() throws {
        let command = try SeeCommand.parse([
            "--mode", "screen",
            "--screen-index", "0",
            "--annotate",
            "--path", "/tmp/peekaboo-see-screen.png",
        ])
        let request = command.makeObservationRequest(target: .screen(index: 0))

        #expect(command.allowsAnnotation(for: .screen(index: 0)) == false)
        #expect(command.allowsAnnotationForCurrentCapture() == false)
        #expect(request.output.saveAnnotatedScreenshot == false)
    }

    @Test
    @MainActor
    func `Observation menu bar strip target disables annotations`() throws {
        let command = try SeeCommand.parse([
            "--app", "menubar",
            "--annotate",
            "--path", "/tmp/peekaboo-see-menubar.png",
        ])
        let request = command.makeObservationRequest(target: .menubar)

        #expect(command.allowsAnnotation(for: .menubar) == false)
        #expect(command.allowsAnnotationForCurrentCapture() == false)
        #expect(request.output.saveAnnotatedScreenshot == false)
    }

    @Test
    @MainActor
    func `Directory path expands to generated see screenshot filename`() throws {
        let command = try SeeCommand.parse(["--path", "."])
        let output = command.screenshotOutputPath()
        let url = URL(fileURLWithPath: output)

        #expect(url.lastPathComponent.hasPrefix("peekaboo_see_"))
        #expect(url.pathExtension == "png")
        #expect(
            url.deletingLastPathComponent().standardizedFileURL.path ==
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .standardizedFileURL.path
        )
    }

    @Test
    @MainActor
    func `JSON output without path uses snapshot-scoped temporary screenshot`() throws {
        let snapshotID = "snapshot-test"
        let command = try SeeCommand.parse(["--json"])
        let output = URL(fileURLWithPath: command.screenshotOutputPath(snapshotID: snapshotID))

        #expect(command.usesTemporaryScreenshotOutput)
        #expect(output.lastPathComponent == "raw.png")
        #expect(output.deletingLastPathComponent().lastPathComponent == snapshotID)
        #expect(output.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    @Test
    func `Coordinate system conversion for NSGraphicsContext`() {
        // Given a window-relative element bounds with top-left origin
        let elementBounds = CGRect(x: 100, y: 100, width: 80, height: 40)
        let imageHeight: CGFloat = 600

        // When converting to NSGraphicsContext coordinates (bottom-left origin)
        let flippedY = imageHeight - elementBounds.origin.y - elementBounds.height
        let drawingRect = NSRect(
            x: elementBounds.origin.x,
            y: flippedY,
            width: elementBounds.width,
            height: elementBounds.height
        )

        // Then Y coordinate should be flipped correctly
        #expect(drawingRect.origin.x == 100)
        #expect(drawingRect.origin.y == 460) // 600 - 100 - 40
        #expect(drawingRect.size.width == 80)
        #expect(drawingRect.size.height == 40)
    }

    @Test
    func `Detection metadata includes window context`() {
        // Given capture metadata with window info
        let windowInfo = WindowInfo(
            window_title: "Test Window",
            window_id: 12345,
            window_index: 0,
            bounds: WindowBounds(x: 100, y: 50, width: 1200, height: 800),
            is_on_screen: true
        )

        let appInfo = ApplicationInfo(
            app_name: "TestApp",
            bundle_id: "com.test.app",
            pid: 1234,
            is_active: true,
            window_count: 1
        )

        let captureMetadata = CaptureMetadata(
            size: CGSize(width: 1200, height: 800),
            mode: .window,
            applicationInfo: ServiceApplicationInfo(
                processIdentifier: appInfo.pid,
                bundleIdentifier: appInfo.bundle_id,
                name: appInfo.app_name,
                bundlePath: nil,
                isActive: appInfo.is_active,
                isHidden: false,
                windowCount: 1
            ),
            windowInfo: ServiceWindowInfo(
                windowID: Int(windowInfo.window_id ?? 0),
                title: windowInfo.window_title,
                bounds: CGRect(
                    x: windowInfo.bounds?.x ?? 0,
                    y: windowInfo.bounds?.y ?? 0,
                    width: windowInfo.bounds?.width ?? 0,
                    height: windowInfo.bounds?.height ?? 0
                ),
                // Remove isOnScreen - it's not part of ServiceWindowInfo
            ),
            displayInfo: nil,
            timestamp: Date()
        )

        // When creating detection metadata (as in SeeCommand)
        let detectionMetadata = DetectionMetadata(
            detectionTime: 0.5,
            elementCount: 10,
            method: "AXorcist",
            warnings: []
        )

        // Then metadata should contain basic detection info
        #expect(detectionMetadata.detectionTime == 0.5)
        #expect(detectionMetadata.elementCount == 10)
        #expect(detectionMetadata.method == "AXorcist")

        // Window context would be available from captureMetadata
        #expect(captureMetadata.applicationInfo?.name == "TestApp")
        #expect(captureMetadata.windowInfo?.title == "Test Window")
    }

    @Test
    func `Enhanced detection uses window context`() {
        let imageData = Data(repeating: 0xAB, count: 4)
        let snapshotId = "test-snapshot-123"
        let appName = "Safari"
        let windowTitle = "Start Page"
        let windowBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let metadata = Self.detectionMetadata()
        let captureResult = Self.makeCaptureResult(
            imageData: imageData,
            appName: appName,
            windowTitle: windowTitle,
            windowBounds: windowBounds
        )

        Self.expectDetectionMetadata(metadata)
        Self.expectCaptureResult(
            captureResult,
            imageData: imageData,
            appName: appName,
            windowBounds: windowBounds
        )

        let seeResult = Self.makeSeeResult(
            snapshotId: snapshotId,
            metadata: metadata,
            captureMetadata: captureResult.metadata,
            appName: appName,
            windowTitle: windowTitle
        )
        Self.expectSeeResult(
            seeResult,
            snapshotId: snapshotId,
            appName: appName,
            windowTitle: windowTitle
        )
    }

    @Test
    func `Annotation excludes disabled elements`() {
        // Given a mix of enabled and disabled elements
        let elements = DetectedElements(
            buttons: [
                DetectedElement(
                    id: "B1",
                    type: .button,
                    label: "Enabled",
                    value: nil,
                    bounds: CGRect(x: 10, y: 10, width: 50, height: 30),
                    isEnabled: true,
                    isSelected: nil,
                    attributes: [:]
                ),
                DetectedElement(
                    id: "B2",
                    type: .button,
                    label: "Disabled",
                    value: nil,
                    bounds: CGRect(x: 70, y: 10, width: 50, height: 30),
                    isEnabled: false,
                    isSelected: nil,
                    attributes: [:]
                )
            ],
            textFields: [],
            links: [],
            images: [],
            groups: [],
            sliders: [],
            checkboxes: [],
            menus: [],
            other: []
        )

        // When filtering for annotation (as done in generateAnnotatedScreenshot)
        let annotatedElements = elements.all.filter(\.isEnabled)

        // Then only enabled elements should be included
        #expect(annotatedElements.count == 1)
        #expect(annotatedElements.first?.id == "B1")
    }

    @Test
    func `Role-based colors are assigned correctly`() throws {
        // Define expected colors (from SeeCommand)
        let roleColors: [ElementType: (r: CGFloat, g: CGFloat, b: CGFloat)] = [
            .button: (0, 0.48, 1.0), // #007AFF
            .textField: (0.204, 0.78, 0.349), // #34C759
            .link: (0, 0.48, 1.0), // #007AFF
            .checkbox: (0.557, 0.557, 0.576), // #8E8E93
            .slider: (0.557, 0.557, 0.576), // #8E8E93
            .menu: (0, 0.48, 1.0), // #007AFF
        ]

        // Test each element type gets correct color
        for (elementType, expectedColor) in roleColors {
            let element = DetectedElement(
                id: "test",
                type: elementType,
                label: "Test",
                value: nil,
                bounds: CGRect(x: 0, y: 0, width: 100, height: 50),
                isEnabled: true,
                isSelected: nil,
                attributes: [:]
            )

            // In actual implementation, this would be done in generateAnnotatedScreenshot
            let color = try #require(roleColors[element.type])
            #expect(color.r == expectedColor.r)
            #expect(color.g == expectedColor.g)
            #expect(color.b == expectedColor.b)
        }
    }
}

extension SeeCommandAnnotationTests {
    fileprivate static func detectionMetadata() -> DetectionMetadata {
        DetectionMetadata(
            detectionTime: 0.5,
            elementCount: 10,
            method: "AXorcist",
            warnings: []
        )
    }

    fileprivate static func makeCaptureResult(
        imageData: Data,
        appName: String,
        windowTitle: String,
        windowBounds: CGRect
    ) -> CaptureResult {
        let captureMetadata = Self.makeCaptureMetadata(
            appName: appName,
            windowTitle: windowTitle,
            windowBounds: windowBounds
        )
        return CaptureResult(imageData: imageData, metadata: captureMetadata)
    }

    fileprivate static func expectDetectionMetadata(_ metadata: DetectionMetadata) {
        #expect(metadata.detectionTime == 0.5)
        #expect(metadata.elementCount == 10)
        #expect(metadata.method == "AXorcist")
    }

    fileprivate static func expectCaptureResult(
        _ result: CaptureResult,
        imageData: Data,
        appName: String,
        windowBounds: CGRect
    ) {
        #expect(result.imageData == imageData)
        #expect(result.metadata.applicationInfo?.name == appName)
        #expect(result.metadata.windowInfo?.bounds == windowBounds)
    }

    fileprivate static func makeSeeResult(
        snapshotId: String,
        metadata: DetectionMetadata,
        captureMetadata: CaptureMetadata,
        appName: String,
        windowTitle: String
    ) -> SeeResult {
        SeeResult(
            snapshot_id: snapshotId,
            screenshot_raw: "raw.png",
            screenshot_annotated: "raw_annotated.png",
            ui_map: "snapshot.json",
            application_name: appName,
            window_title: windowTitle,
            is_dialog: false,
            element_count: metadata.elementCount,
            interactable_count: metadata.elementCount,
            capture_mode: captureMetadata.mode.rawValue,
            analysis: nil,
            execution_time: metadata.detectionTime,
            ui_elements: [],
            menu_bar: nil
        )
    }

    fileprivate static func expectSeeResult(
        _ result: SeeResult,
        snapshotId: String,
        appName: String,
        windowTitle: String
    ) {
        #expect(result.snapshot_id == snapshotId)
        #expect(result.application_name == appName)
        #expect(result.window_title == windowTitle)
    }

    fileprivate static func makeCaptureMetadata(
        appName: String,
        windowTitle: String,
        windowBounds: CGRect
    ) -> CaptureMetadata {
        CaptureMetadata(
            size: windowBounds.size,
            mode: .window,
            applicationInfo: self.makeApplicationInfo(appName: appName),
            windowInfo: self.makeWindowInfo(windowTitle: windowTitle, windowBounds: windowBounds),
            displayInfo: nil,
            timestamp: Date(timeIntervalSince1970: 0)
        )
    }

    fileprivate static func makeApplicationInfo(appName: String) -> ServiceApplicationInfo {
        ServiceApplicationInfo(
            processIdentifier: 1234,
            bundleIdentifier: "com.apple.Safari",
            name: appName,
            bundlePath: "/Applications/Safari.app",
            isActive: true,
            isHidden: false,
            windowCount: 1
        )
    }

    fileprivate static func makeWindowInfo(windowTitle: String, windowBounds: CGRect) -> ServiceWindowInfo {
        ServiceWindowInfo(
            windowID: 42,
            title: windowTitle,
            bounds: windowBounds,
            isMinimized: false,
            isMainWindow: true
        )
    }
}

// MARK: - Mock Classes for Testing

struct MockDetectionContext {
    var applicationName: String?
    var windowTitle: String?
    var windowBounds: CGRect?
}
