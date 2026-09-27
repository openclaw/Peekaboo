import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing

@MainActor
final class VerifyStateApplicationService: ApplicationServiceProtocol {
    let applications: [ServiceApplicationInfo]
    let windows: [ServiceWindowInfo]
    let applicationStatus: UnifiedToolOutput<ServiceApplicationListData>.Summary.Status
    let applicationWarnings: [String]
    let applicationLists: [[ServiceApplicationInfo]]?
    let onListApplications: (@MainActor (Int) -> Void)?
    let applicationLookups: [ServiceApplicationInfo?]?
    let onFindApplication: (@MainActor (Int) async throws -> Void)?
    let windowStatus: UnifiedToolOutput<ServiceWindowListData>.Summary.Status
    let warnings: [String]
    let delay: Duration?
    let onListWindows: (@MainActor () async -> Void)?
    private(set) var listApplicationsCallCount = 0
    private(set) var findApplicationIdentifiers: [String] = []
    private(set) var listWindowsCallCount = 0

    init(
        applications: [ServiceApplicationInfo],
        windows: [ServiceWindowInfo],
        applicationStatus: UnifiedToolOutput<ServiceApplicationListData>.Summary.Status = .success,
        applicationWarnings: [String] = [],
        applicationLists: [[ServiceApplicationInfo]]? = nil,
        onListApplications: (@MainActor (Int) -> Void)? = nil,
        applicationLookups: [ServiceApplicationInfo?]? = nil,
        onFindApplication: (@MainActor (Int) async throws -> Void)? = nil,
        windowStatus: UnifiedToolOutput<ServiceWindowListData>.Summary.Status = .success,
        warnings: [String] = [],
        delay: Duration? = nil,
        onListWindows: (@MainActor () async -> Void)? = nil)
    {
        self.applications = applications
        self.windows = windows
        self.applicationStatus = applicationStatus
        self.applicationWarnings = applicationWarnings
        self.applicationLists = applicationLists
        self.onListApplications = onListApplications
        self.applicationLookups = applicationLookups
        self.onFindApplication = onFindApplication
        self.windowStatus = windowStatus
        self.warnings = warnings
        self.delay = delay
        self.onListWindows = onListWindows
    }

    func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData> {
        let resolvedApplications = if let applicationLists, !applicationLists.isEmpty {
            applicationLists[min(self.listApplicationsCallCount, applicationLists.count - 1)]
        } else {
            self.applications
        }
        self.listApplicationsCallCount += 1
        self.onListApplications?(self.listApplicationsCallCount)
        return UnifiedToolOutput(
            data: ServiceApplicationListData(applications: resolvedApplications),
            summary: .init(brief: "applications", status: self.applicationStatus),
            metadata: .init(duration: 0, warnings: self.applicationWarnings))
    }

    func findApplication(identifier: String) async throws -> ServiceApplicationInfo {
        self.findApplicationIdentifiers.append(identifier)
        try await self.onFindApplication?(self.findApplicationIdentifiers.count)
        if let applicationLookups, !applicationLookups.isEmpty {
            let index = min(self.findApplicationIdentifiers.count - 1, applicationLookups.count - 1)
            guard let application = applicationLookups[index]
            else { throw PeekabooError.appNotFound(identifier) }
            return application
        }
        guard let application = self.applications.first(where: {
            $0.name == identifier || $0.bundleIdentifier == identifier || identifier == "PID:\($0.processIdentifier)"
        }) else {
            throw PeekabooError.appNotFound(identifier)
        }
        return application
    }

    func listWindows(for appIdentifier: String, timeout _: Float?) async throws
        -> UnifiedToolOutput<ServiceWindowListData>
    {
        self.listWindowsCallCount += 1
        await self.onListWindows?()
        if let delay {
            await verifyStateNonCooperativeDelay(delay)
        }
        let application = try await self.findApplication(identifier: appIdentifier)
        return UnifiedToolOutput(
            data: ServiceWindowListData(windows: self.windows, targetApplication: application),
            summary: .init(brief: "windows", status: self.windowStatus),
            metadata: .init(duration: 0, warnings: self.warnings))
    }

    func getFrontmostApplication() async throws -> ServiceApplicationInfo {
        try #require(self.applications.first)
    }

    func isApplicationRunning(identifier: String) async -> Bool {
        await (try? self.findApplication(identifier: identifier)) != nil
    }

    func launchApplication(identifier _: String) async throws -> ServiceApplicationInfo {
        throw UnusedCall()
    }

    func activateApplication(identifier _: String) async throws {
        throw UnusedCall()
    }

    func quitApplication(identifier _: String, force _: Bool) async throws -> Bool {
        throw UnusedCall()
    }

    func hideApplication(identifier _: String) async throws {
        throw UnusedCall()
    }

    func unhideApplication(identifier _: String) async throws {
        throw UnusedCall()
    }

    func hideOtherApplications(identifier _: String) async throws {
        throw UnusedCall()
    }

    func showAllApplications() async throws {
        throw UnusedCall()
    }
}

@MainActor
final class VerifyStateScreenCaptureService: ScreenCaptureServiceProtocol {
    private(set) var windowIDs: [CGWindowID] = []
    private(set) var visualizerModes: [CaptureVisualizerMode] = []
    let applicationInfo: ServiceApplicationInfo?
    let windowInfo: ServiceWindowInfo?
    let delay: Duration?
    private let onCapture: (@MainActor () async throws -> Void)?
    private(set) var permissionCheckCount = 0

    init(
        applicationInfo: ServiceApplicationInfo? = nil,
        windowInfo: ServiceWindowInfo? = nil,
        delay: Duration? = nil,
        onCapture: (@MainActor () async throws -> Void)? = nil)
    {
        self.applicationInfo = applicationInfo
        self.windowInfo = windowInfo
        self.delay = delay
        self.onCapture = onCapture
    }

    func captureWindow(
        windowID: CGWindowID,
        visualizerMode: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.windowIDs.append(windowID)
        self.visualizerModes.append(visualizerMode)
        try await self.onCapture?()
        if let delay {
            await verifyStateNonCooperativeDelay(delay)
        }
        return CaptureResult(
            imageData: Data([0x89, 0x50, 0x4E, 0x47]),
            metadata: CaptureMetadata(
                size: CGSize(width: 1, height: 1),
                mode: .window,
                applicationInfo: self.applicationInfo,
                windowInfo: self.windowInfo))
    }

    func hasScreenRecordingPermission() async -> Bool {
        self.permissionCheckCount += 1
        return true
    }

    func captureScreen(
        displayIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw UnusedCall()
    }

    func captureWindow(
        appIdentifier _: String,
        windowIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw UnusedCall()
    }

    func captureFrontmost(
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw UnusedCall()
    }

    func captureArea(
        _: CGRect,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw UnusedCall()
    }
}

private struct UnusedCall: Error {}

func verifyStateNonCooperativeDelay(_ duration: Duration) async {
    await withCheckedContinuation { continuation in
        Task.detached {
            try? await Task.sleep(for: duration)
            continuation.resume()
        }
    }
}
