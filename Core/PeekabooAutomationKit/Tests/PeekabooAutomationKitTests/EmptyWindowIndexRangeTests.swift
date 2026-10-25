import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@Suite("Empty window index range")
@MainActor
struct EmptyWindowIndexRangeTests {
    @Test
    func `an application with no windows does not report a negative index range`() async throws {
        let service = try Self.makeService(windows: [])
        do {
            _ = try await service.listWindows(target: .index(app: "Stats", index: 0))
            Issue.record("Expected an out-of-range window index to be rejected")
        } catch let error as PeekabooError {
            #expect(error.errorDescription ==
                "Invalid input: windowIndex: Index 0 is out of range. No windows are available.")
        }
    }

    @Test
    func `a populated window list keeps the last valid index`() async throws {
        let window = ServiceWindowInfo(
            windowID: 7,
            title: "Only",
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let service = try Self.makeService(windows: [window])
        do {
            _ = try await service.listWindows(target: .index(app: "Notes", index: 2))
            Issue.record("Expected an out-of-range window index to be rejected")
        } catch let error as PeekabooError {
            #expect(error.errorDescription ==
                "Invalid input: windowIndex: Index 2 is out of range. Available windows: 0-0")
        }
    }

    private static func makeService(windows: [ServiceWindowInfo]) throws -> WindowManagementService {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-empty-window-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return WindowManagementService(
            applicationService: FixedWindowListService(windows: windows),
            feedbackClient: NoopAutomationFeedbackClient(),
            operationLaneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root))
    }
}

@MainActor
private final class FixedWindowListService: ApplicationServiceProtocol {
    private let windows: [ServiceWindowInfo]

    init(windows: [ServiceWindowInfo]) {
        self.windows = windows
    }

    func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData> {
        fatalError("unused")
    }

    func findApplication(identifier _: String) async throws -> ServiceApplicationInfo {
        fatalError("unused")
    }

    func listWindows(
        for _: String,
        timeout _: Float?) async throws -> UnifiedToolOutput<ServiceWindowListData>
    {
        UnifiedToolOutput(
            data: ServiceWindowListData(windows: self.windows),
            summary: .init(brief: "windows", status: .success),
            metadata: .init(duration: 0))
    }

    func getFrontmostApplication() async throws -> ServiceApplicationInfo {
        fatalError("unused")
    }

    func isApplicationRunning(identifier _: String) async -> Bool {
        true
    }

    func launchApplication(identifier _: String) async throws -> ServiceApplicationInfo {
        fatalError("unused")
    }

    func activateApplication(identifier _: String) async throws {}

    func quitApplication(identifier _: String, force _: Bool) async throws -> Bool {
        false
    }

    func hideApplication(identifier _: String) async throws {}

    func unhideApplication(identifier _: String) async throws {}

    func hideOtherApplications(identifier _: String) async throws {}

    func showAllApplications() async throws {}
}
