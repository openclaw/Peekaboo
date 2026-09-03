//
//  ScreenCaptureService+Testing.swift
//  PeekabooCore
//

import AppKit
import CoreGraphics
import Foundation
import PeekabooFoundation

extension ScreenCaptureService {
    @MainActor
    @_spi(Testing) public static func withIsolatedCaptureCoordination<T: Sendable>(
        directory: URL,
        operation: @MainActor () async throws -> T) async rethrows -> T
    {
        let coordination = ScreenCaptureKitCaptureGate.Coordination(
            operationLockPath: directory.appendingPathComponent("operation.lock").path,
            coordinator: ScreenCaptureKitOperationCoordinator(
                lockFilePath: directory.appendingPathComponent("capture.lock").path))
        return try await ScreenCaptureKitCaptureGate.$coordinationOverride.withValue(coordination) {
            try await ScreenCaptureKitCaptureGate.$processOwnerClaimOverride.withValue({
                throw ScreenCaptureKitOwnerLease.LeaseError.invalidOwnerIdentity(
                    "Synthetic capture must inject its owner claim")
            }, operation: operation)
        }
    }

    @_spi(Testing) public struct TestFixtures: Sendable {
        @_spi(Testing) public struct Display: Sendable {
            public let name: String
            public let bounds: CGRect
            public let scaleFactor: CGFloat
            public let imageSize: CGSize
            public let imageData: Data

            public init(
                name: String,
                bounds: CGRect,
                scaleFactor: CGFloat,
                imageSize: CGSize,
                imageData: Data)
            {
                self.name = name
                self.bounds = bounds
                self.scaleFactor = scaleFactor
                self.imageSize = imageSize
                self.imageData = imageData
            }
        }

        @_spi(Testing) public struct Window: Sendable {
            public let application: ServiceApplicationInfo
            public let title: String
            public let bounds: CGRect
            public let imageData: Data

            public init(
                application: ServiceApplicationInfo,
                title: String,
                bounds: CGRect,
                imageData: Data)
            {
                self.application = application
                self.title = title
                self.bounds = bounds
                self.imageData = imageData
            }
        }

        public let displays: [Display]
        public let windowsByPID: [Int32: [Window]]
        public let applicationsByIdentifier: [String: ServiceApplicationInfo]
        public let frontmostApplication: ServiceApplicationInfo?

        public init(
            displays: [Display],
            windows: [Window] = [],
            frontmostApplication: ServiceApplicationInfo? = nil)
        {
            precondition(!displays.isEmpty, "At least one display fixture is required")
            self.displays = displays
            self.windowsByPID = Dictionary(grouping: windows, by: { $0.application.processIdentifier })
            self.frontmostApplication = frontmostApplication ?? windows.first?.application

            var lookup: [String: ServiceApplicationInfo] = [:]
            for window in windows {
                let app = window.application
                lookup[app.name.lowercased()] = app
                if let bundle = app.bundleIdentifier?.lowercased() {
                    lookup[bundle] = app
                }
                lookup["pid:\(app.processIdentifier)"] = app
            }
            self.applicationsByIdentifier = lookup
        }

        @_spi(Testing) public func display(at index: Int?) throws -> Display {
            if let index {
                guard index >= 0, index < self.displays.count else {
                    throw PeekabooError.invalidInput(
                        """
                        displayIndex: Index \(index) is out of range. Available displays: 0-\(self.displays.count - 1)
                        """)
                }
                return self.displays[index]
            }
            return self.displays[0]
        }

        @_spi(Testing) public func windows(for app: ServiceApplicationInfo) -> [Window] {
            self.windowsByPID[app.processIdentifier] ?? []
        }

        @_spi(Testing) public func application(for identifier: String) -> ServiceApplicationInfo? {
            self.applicationsByIdentifier[identifier.lowercased()]
        }

        @MainActor
        @_spi(Testing) public static func makeImage(
            width: Int,
            height: Int,
            color: NSColor = .white) -> Data
        {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo)
            else {
                return Data()
            }
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            guard let cgImage = context.makeImage() else { return Data() }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else {
                return Data()
            }
            return png
        }
    }

    @MainActor
    @_spi(Testing) public static func makeTestService(
        fixtures: TestFixtures,
        permissionGranted: Bool = true,
        apis: [ScreenCaptureAPI] = [.modern],
        loggingService: any LoggingServiceProtocol = MockLoggingService()) -> ScreenCaptureService
    {
        let dependencies = Dependencies(
            feedbackClient: MockVisualizationClient(),
            permissionEvaluator: StubPermissionEvaluator(granted: permissionGranted),
            fallbackRunner: ScreenCaptureFallbackRunner(apis: apis),
            applicationResolver: FixtureApplicationResolver(fixtures: fixtures),
            makeFrameSource: { _ in NoOpCaptureFrameSource() },
            makeModernOperator: { _, _ in
                MockModernCaptureOperator(fixtures: fixtures)
            },
            makeLegacyOperator: { _ in
                MockModernCaptureOperator(fixtures: fixtures)
            },
            screenLockProbe: { false })
        return ScreenCaptureService(loggingService: loggingService, dependencies: dependencies)
    }
}

private struct StubPermissionEvaluator: ScreenRecordingPermissionEvaluating {
    let granted: Bool
    func hasPermission(
        logger: CategoryLogger,
        policy _: ScreenRecordingPermissionProbePolicy) async -> Bool
    {
        if !self.granted {
            logger.warning("Test harness denying permission for screen capture")
        }
        return self.granted
    }
}

@MainActor
private final class MockVisualizationClient: AutomationFeedbackClient, @unchecked Sendable {
    private(set) var flashes: [CGRect] = []

    func connect() {}

    func showScreenshotFlash(in rect: CGRect) async -> Bool {
        self.flashes.append(rect)
        return true
    }

    func showWatchCapture(in rect: CGRect) async -> Bool {
        self.flashes.append(rect)
        return true
    }
}

private struct FixtureApplicationResolver: ApplicationResolving {
    let fixtures: ScreenCaptureService.TestFixtures

    func findApplication(identifier: String) async throws -> ServiceApplicationInfo {
        if let app = fixtures.application(for: identifier) {
            return app
        }
        throw NotFoundError.application(identifier)
    }

    func frontmostApplication() async throws -> ServiceApplicationInfo {
        guard let app = fixtures.frontmostApplication else {
            throw NotFoundError.application("frontmost")
        }
        return app
    }
}

private struct NoOpCaptureFrameSource: CaptureFrameSource {
    @MainActor
    func nextFrame() async throws -> (cgImage: CGImage?, metadata: CaptureMetadata)? {
        nil
    }
}

private final class MockModernCaptureOperator: ModernScreenCaptureOperating, LegacyScreenCaptureOperating,
@unchecked Sendable {
    private let fixtures: ScreenCaptureService.TestFixtures

    init(fixtures: ScreenCaptureService.TestFixtures) {
        self.fixtures = fixtures
    }

    func captureScreen(
        displayIndex: Int?,
        correlationId: String,
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        let display = try fixtures.display(at: displayIndex)
        let logicalSize = display.bounds.size
        let scaleFactor = scale == .native ? display.scaleFactor : 1.0
        let outputSize = CGSize(width: logicalSize.width * scaleFactor, height: logicalSize.height * scaleFactor)
        let imageData = await MainActor.run {
            ScreenCaptureService.TestFixtures.makeImage(
                width: Int(outputSize.width),
                height: Int(outputSize.height),
                color: .systemBlue)
        }
        let metadata = CaptureMetadata(
            size: outputSize,
            mode: .screen,
            displayInfo: DisplayInfo(
                index: displayIndex ?? 0,
                name: display.name,
                bounds: display.bounds,
                scaleFactor: scale == .native ? display.scaleFactor : 1.0))
        return CaptureResult(imageData: imageData, metadata: metadata)
    }

    func captureWindow(
        app: ServiceApplicationInfo,
        windowIndex: Int?,
        correlationId: String,
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        let windows = self.fixtures.windows(for: app)
        guard !windows.isEmpty else {
            throw NotFoundError.window(app: app.name)
        }

        let target: ScreenCaptureService.TestFixtures.Window
        if let index = windowIndex {
            guard index >= 0, index < windows.count else {
                throw PeekabooError.invalidInput(
                    "windowIndex: Index \(index) is out of range. Available windows: 0-\(windows.count - 1)")
            }
            target = windows[index]
        } else {
            target = windows[0]
        }

        let scaleFactor = scale == .native ? (self.fixtures.displays.first?.scaleFactor ?? 1.0) : 1.0
        let outputSize = CGSize(width: target.bounds.width * scaleFactor, height: target.bounds.height * scaleFactor)
        let imageData = await MainActor.run {
            ScreenCaptureService.TestFixtures.makeImage(
                width: Int(outputSize.width),
                height: Int(outputSize.height),
                color: .systemGreen)
        }

        let metadata = CaptureMetadata(
            size: outputSize,
            mode: .window,
            applicationInfo: app,
            windowInfo: ServiceWindowInfo(
                windowID: target.title.hashValue,
                title: target.title,
                bounds: target.bounds,
                isMinimized: false,
                isMainWindow: true,
                windowLevel: 0,
                alpha: 1.0,
                index: windowIndex ?? 0),
            displayInfo: DisplayInfo(
                index: 0,
                name: self.fixtures.displays.first?.name,
                bounds: self.fixtures.displays.first?.bounds ?? target.bounds,
                scaleFactor: scale == .native ? (self.fixtures.displays.first?.scaleFactor ?? 1.0) : 1.0))
        return CaptureResult(imageData: imageData, metadata: metadata)
    }

    func captureWindow(
        windowID: CGWindowID,
        correlationId _: String,
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        let allWindows = self.fixtures.windowsByPID.values.flatMap(\.self)
        guard let target = allWindows.first(where: { CGWindowID($0.title.hashValue) == windowID }) else {
            throw PeekabooError.windowNotFound(criteria: "window_id \(windowID)")
        }

        let scaleFactor = scale == .native ? (self.fixtures.displays.first?.scaleFactor ?? 1.0) : 1.0
        let outputSize = CGSize(width: target.bounds.width * scaleFactor, height: target.bounds.height * scaleFactor)
        let imageData = await MainActor.run {
            ScreenCaptureService.TestFixtures.makeImage(
                width: Int(outputSize.width),
                height: Int(outputSize.height),
                color: .systemGreen)
        }

        let metadata = CaptureMetadata(
            size: outputSize,
            mode: .window,
            applicationInfo: target.application,
            windowInfo: ServiceWindowInfo(
                windowID: Int(windowID),
                title: target.title,
                bounds: target.bounds,
                isMinimized: false,
                isMainWindow: true,
                windowLevel: 0,
                alpha: 1.0,
                index: 0),
            displayInfo: DisplayInfo(
                index: 0,
                name: self.fixtures.displays.first?.name,
                bounds: self.fixtures.displays.first?.bounds ?? target.bounds,
                scaleFactor: scale == .native ? (self.fixtures.displays.first?.scaleFactor ?? 1.0) : 1.0))
        return CaptureResult(imageData: imageData, metadata: metadata)
    }

    func captureArea(
        _ rect: CGRect,
        correlationId: String,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        let width = max(1, Int(rect.width.rounded()))
        let height = max(1, Int(rect.height.rounded()))
        let scaleFactor = scale == .native ? (self.fixtures.displays.first?.scaleFactor ?? 1.0) : 1.0
        let imageData = await MainActor.run {
            ScreenCaptureService.TestFixtures.makeImage(
                width: Int(CGFloat(width) * scaleFactor),
                height: Int(CGFloat(height) * scaleFactor),
                color: .systemGray)
        }
        let metadata = CaptureMetadata(
            size: CGSize(width: CGFloat(width) * scaleFactor, height: CGFloat(height) * scaleFactor),
            mode: .area,
            displayInfo: DisplayInfo(
                index: 0,
                name: self.fixtures.displays.first?.name,
                bounds: rect,
                scaleFactor: scale == .native ? (self.fixtures.displays.first?.scaleFactor ?? 1.0) : 1.0))
        return CaptureResult(imageData: imageData, metadata: metadata)
    }
}
