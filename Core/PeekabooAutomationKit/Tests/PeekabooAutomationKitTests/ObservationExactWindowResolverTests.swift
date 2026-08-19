import CoreGraphics
import XCTest
@testable import PeekabooAutomationKit

@MainActor
final class ObservationExactWindowResolverTests: XCTestCase {
    func testExactPIDSkipsRunningApplicationEnumeration() async throws {
        let app = Self.app(pid: 123)
        let service = ExactWindowApplicationService(app: app, windows: [])
        let snapshotProvider = DesktopStateSnapshotProvider(applications: service)
        let resolver = ObservationTargetResolver(
            applications: service,
            exactWindowMetadataProvider: TestExactWindowMetadataProvider { windowID in
                Self.metadata(windowID: windowID, ownerPID: 123)
            })

        let target = DesktopObservationTargetRequest.pid(123, window: .id(42))
        let snapshot = try await snapshotProvider.snapshot(for: target)
        let resolved = try await resolver.resolve(target, snapshot: snapshot)

        XCTAssertTrue(snapshot.runningApplications.isEmpty)
        XCTAssertEqual(service.listApplicationsCalls, 0)
        XCTAssertEqual(service.findApplicationCalls, 0)
        XCTAssertEqual(service.listWindowsCalls, 0)
        XCTAssertEqual(resolved.app?.processIdentifier, 123)
        XCTAssertEqual(resolved.app?.processStartIdentity, 700)
        XCTAssertEqual(resolved.window?.windowID, 42)
        XCTAssertEqual(resolved.detectionContext?.windowMutationIdentity?.ownerProcessIdentifier, 123)
        XCTAssertEqual(resolved.detectionContext?.windowMutationIdentity?.ownerProcessStartIdentity, 700)
    }

    func testExactPIDWithoutSnapshotFailsClosedForForeignOwnerOrReusedPID() async throws {
        let app = Self.app(pid: 123)
        let service = ExactWindowApplicationService(app: app, windows: [])
        let foreignOwner = ObservationTargetResolver(
            applications: service,
            exactWindowMetadataProvider: TestExactWindowMetadataProvider { windowID in
                Self.metadata(windowID: windowID, ownerPID: 999)
            })
        let reusedPID = ObservationTargetResolver(
            applications: service,
            exactWindowMetadataProvider: TestExactWindowMetadataProvider(liveProcessStartIdentity: 701) { windowID in
                Self.metadata(windowID: windowID, ownerPID: 123)
            })

        for resolver in [foreignOwner, reusedPID] {
            do {
                _ = try await resolver.resolve(
                    .pid(123, window: .id(42)),
                    snapshot: DesktopStateSnapshot())
                XCTFail("Expected an unverified exact PID/window receipt to fail")
            } catch is DesktopObservationError {
                // Expected.
            }
        }
        XCTAssertEqual(service.listApplicationsCalls, 0)
        XCTAssertEqual(service.listWindowsCalls, 0)
    }

    func testExactIDUsesCGMetadataWithoutListingAXWindows() async throws {
        let app = Self.app(pid: 123)
        let service = ExactWindowApplicationService(app: app, windows: [Self.serviceWindow(id: 42)])
        let resolver = ObservationTargetResolver(
            applications: service,
            exactWindowMetadataProvider: TestExactWindowMetadataProvider { windowID in
                Self.metadata(windowID: windowID, ownerPID: 123)
            })

        let resolved = try await resolver.resolve(
            .pid(123, window: .id(42)),
            snapshot: DesktopStateSnapshot(runningApplications: [ApplicationIdentity(app)]))

        XCTAssertEqual(resolved.kind, .windowID(42))
        XCTAssertEqual(resolved.window?.windowID, 42)
        XCTAssertEqual(resolved.detectionContext?.applicationBundleId, "com.example.fixture")
        XCTAssertTrue(resolved.selectorResolutionProofs?.isEmpty ?? true)
        XCTAssertEqual(service.listWindowsCalls, 0)
    }

    func testAppExactIDPreservesApplicationProofOnExactTarget() async throws {
        let app = Self.app(pid: 123)
        let service = ExactWindowApplicationService(app: app, windows: [])
        let resolver = ObservationTargetResolver(
            applications: service,
            exactWindowMetadataProvider: TestExactWindowMetadataProvider { windowID in
                Self.metadata(windowID: windowID, ownerPID: 123)
            })

        let resolved = try await resolver.resolve(
            .app(identifier: "com.example.fixture", window: .id(42)),
            snapshot: DesktopStateSnapshot(runningApplications: [ApplicationIdentity(app)]))

        let proof = try XCTUnwrap(resolved.selectorResolutionProofs?.first)
        let exactIdentity = try XCTUnwrap(resolved.detectionContext?.windowMutationIdentity)
        XCTAssertEqual(resolved.selectorResolutionProofs?.count, 1)
        XCTAssertEqual(proof.scope, .application)
        XCTAssertEqual(proof.normalizedSelector, "com.example.fixture")
        XCTAssertTrue(proof.selectedWindowIdentity?.hasSameStableReceipt(as: exactIdentity) == true)
        XCTAssertEqual(service.listWindowsCalls, 0)
    }

    func testForeignAndMissingExactIDsFailWithoutListingAXWindows() async throws {
        let app = Self.app(pid: 123)
        let service = ExactWindowApplicationService(app: app, windows: [Self.serviceWindow(id: 42)])
        let foreignResolver = ObservationTargetResolver(
            applications: service,
            exactWindowMetadataProvider: TestExactWindowMetadataProvider { windowID in
                Self.metadata(windowID: windowID, ownerPID: 999)
            })

        do {
            _ = try await foreignResolver.resolve(
                .pid(123, window: .id(42)),
                snapshot: DesktopStateSnapshot(runningApplications: [ApplicationIdentity(app)]))
            XCTFail("Expected foreign exact window to fail")
        } catch is DesktopObservationError {
            // Expected.
        }
        XCTAssertEqual(service.listWindowsCalls, 0)

        let missingResolver = ObservationTargetResolver(
            applications: service,
            exactWindowMetadataProvider: TestExactWindowMetadataProvider { _ in nil })
        do {
            _ = try await missingResolver.resolve(
                .pid(123, window: .id(404)),
                snapshot: DesktopStateSnapshot(runningApplications: [ApplicationIdentity(app)]))
            XCTFail("Expected missing exact window to fail")
        } catch is DesktopObservationError {
            // Expected.
        }
        XCTAssertEqual(service.listWindowsCalls, 0)
    }

    func testNonExactSelectionStillUsesWindowCatalog() async throws {
        let app = Self.app(pid: 123)
        let service = ExactWindowApplicationService(app: app, windows: [Self.serviceWindow(id: 42)])
        let resolver = ObservationTargetResolver(
            applications: service,
            exactWindowMetadataProvider: TestExactWindowMetadataProvider { _ in nil })

        let resolved = try await resolver.resolve(
            .pid(123, window: .title("Editor")),
            snapshot: DesktopStateSnapshot(runningApplications: [ApplicationIdentity(app)]))

        XCTAssertEqual(resolved.window?.windowID, 42)
        XCTAssertEqual(service.listWindowsCalls, 1)
    }

    func testAutomaticSelectionUsesWindowServerCatalogWithoutListingAXWindows() async throws {
        let app = Self.app(pid: 123)
        let service = ExactWindowApplicationService(app: app, windows: [Self.serviceWindow(id: 99)])
        let nativeWindow = SystemWindowIdentity(
            windowID: 42,
            ownerProcessIdentifier: app.processIdentifier,
            ownerProcessStartIdentity: 700,
            title: "Editor",
            bounds: CGRect(x: 10, y: 20, width: 800, height: 600),
            layer: 0,
            alpha: 1,
            isOnScreen: true,
            sharingState: .readOnly)
        let resolver = ObservationTargetResolver(
            applications: service,
            exactWindowMetadataProvider: TestExactWindowMetadataProvider(windows: [nativeWindow]) { windowID in
                guard windowID == nativeWindow.windowID else { return nil }
                return Self.metadata(windowID: windowID, ownerPID: app.processIdentifier)
            })

        let resolved = try await resolver.resolve(
            .pid(123, window: .automatic),
            snapshot: DesktopStateSnapshot(runningApplications: [ApplicationIdentity(app)]))

        XCTAssertEqual(resolved.window?.windowID, 42)
        let proof = try XCTUnwrap(resolved.selectorResolutionProofs?.first)
        let exactIdentity = try XCTUnwrap(resolved.detectionContext?.windowMutationIdentity)
        XCTAssertEqual(resolved.selectorResolutionProofs?.count, 1)
        XCTAssertEqual(proof.scope, .window)
        XCTAssertEqual(proof.normalizedSelector, WindowSelectorResolutionProof.normalizedSelector(.automatic))
        XCTAssertTrue(proof.selectedWindowIdentity?.hasSameStableReceipt(as: exactIdentity) == true)

        let appResolved = try await resolver.resolve(
            .app(identifier: "com.example.fixture", window: .automatic),
            snapshot: DesktopStateSnapshot(runningApplications: [ApplicationIdentity(app)]))
        let appProofs = try XCTUnwrap(appResolved.selectorResolutionProofs)
        XCTAssertEqual(appProofs.map(\.scope), [.application, .window])
        XCTAssertTrue(appProofs.allSatisfy {
            $0.selectedWindowIdentity?.hasSameStableReceipt(as: exactIdentity) == true
        })

        let titleResolved = try await resolver.resolve(
            .pid(123, window: .title("Editor")),
            snapshot: DesktopStateSnapshot(runningApplications: [ApplicationIdentity(app)]))
        let titleProof = try XCTUnwrap(titleResolved.selectorResolutionProofs?.last)
        XCTAssertEqual(titleProof.scope, .window)
        XCTAssertEqual(
            titleProof.normalizedSelector,
            WindowSelectorResolutionProof.normalizedSelector(.title("Editor")))
        XCTAssertTrue(titleProof.selectedWindowIdentity?.hasSameStableReceipt(as: exactIdentity) == true)
        XCTAssertEqual(service.listWindowsCalls, 0)
    }

    func testPIDCatalogRejectsAReusedProcessGenerationWithoutListingAXWindows() async throws {
        let oldApplication = ServiceApplicationInfo(
            processIdentifier: 123,
            processStartIdentity: 100,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture",
            windowCount: 1)
        let replacementWindow = SystemWindowIdentity(
            windowID: 42,
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 200,
            title: "Replacement",
            bounds: CGRect(x: 10, y: 20, width: 800, height: 600),
            layer: 0,
            alpha: 1,
            isOnScreen: true,
            sharingState: .readOnly)
        let service = ExactWindowApplicationService(app: oldApplication, windows: [])
        let resolver = ObservationTargetResolver(
            applications: service,
            exactWindowMetadataProvider: TestExactWindowMetadataProvider(
                windows: [replacementWindow],
                liveProcessStartIdentity: 200)
            { _ in nil })

        do {
            _ = try await resolver.resolve(
                .pid(123, window: .automatic),
                snapshot: DesktopStateSnapshot(runningApplications: [ApplicationIdentity(oldApplication)]))
            XCTFail("Expected reused PID catalog to fail")
        } catch is DesktopObservationError {
            // Expected.
        }

        XCTAssertEqual(service.listWindowsCalls, 0)
    }

    func testTopLevelExactWindowRejectsMissingIDBeforeCaptureResolution() async throws {
        let app = Self.app(pid: 123)
        let service = ExactWindowApplicationService(app: app, windows: [])
        let existingResolver = ObservationTargetResolver(
            applications: service,
            exactWindowMetadataProvider: TestExactWindowMetadataProvider { windowID in
                guard windowID == 42 else { return nil }
                return ExactWindowObservationMetadata(
                    ownerProcessIdentifier: app.processIdentifier,
                    ownerProcessStartIdentity: 700,
                    title: "Editor",
                    bounds: CGRect(x: 10, y: 20, width: 800, height: 600),
                    applicationName: app.name)
            })

        let existing = try await existingResolver.resolve(.windowID(42), snapshot: DesktopStateSnapshot())
        XCTAssertEqual(existing.window?.windowID, 42)
        XCTAssertEqual(existing.app?.name, "Fixture")

        let missingResolver = ObservationTargetResolver(
            applications: service,
            exactWindowMetadataProvider: TestExactWindowMetadataProvider { _ in nil })
        do {
            _ = try await missingResolver.resolve(.windowID(404), snapshot: DesktopStateSnapshot())
            XCTFail("Expected stale top-level window id to fail before capture")
        } catch is DesktopObservationError {
            // Expected.
        }
        XCTAssertEqual(service.listWindowsCalls, 0)
    }

    private static func app(pid: Int32) -> ServiceApplicationInfo {
        ServiceApplicationInfo(
            processIdentifier: pid,
            processStartIdentity: 700,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture",
            windowCount: 1)
    }

    private static func serviceWindow(id: Int) -> ServiceWindowInfo {
        let bounds = CGRect(x: 10, y: 20, width: 800, height: 600)
        return ServiceWindowInfo(
            windowID: id,
            title: "Editor",
            bounds: bounds,
            isMinimized: false,
            isMainWindow: true,
            windowLevel: 0,
            alpha: 1,
            index: 0,
            layer: 0,
            isOnScreen: true,
            sharingState: .readOnly,
            isExcludedFromWindowsMenu: false,
            mutationIdentity: WindowMutationIdentity(
                windowID: id,
                ownerProcessIdentifier: 123,
                ownerProcessStartIdentity: 700,
                capturedBounds: bounds))
    }

    private nonisolated static func metadata(
        windowID: CGWindowID,
        ownerPID: Int32) -> ExactWindowObservationMetadata
    {
        _ = windowID
        return ExactWindowObservationMetadata(
            ownerProcessIdentifier: ownerPID,
            ownerProcessStartIdentity: 700,
            title: "Editor",
            bounds: CGRect(x: 10, y: 20, width: 800, height: 600))
    }
}

private struct TestExactWindowMetadataProvider: ExactWindowMetadataProviding {
    let lookup: @Sendable (CGWindowID) -> ExactWindowObservationMetadata?
    let windowIdentities: [SystemWindowIdentity]
    let liveProcessStartIdentity: UInt64

    init(
        windows: [SystemWindowIdentity] = [],
        liveProcessStartIdentity: UInt64 = 700,
        _ lookup: @escaping @Sendable (CGWindowID) -> ExactWindowObservationMetadata?)
    {
        self.lookup = lookup
        self.windowIdentities = windows
        self.liveProcessStartIdentity = liveProcessStartIdentity
    }

    func metadata(for windowID: CGWindowID) -> ExactWindowObservationMetadata? {
        self.lookup(windowID)
    }

    func windows(for _: Int32) -> [SystemWindowIdentity] {
        self.windowIdentities
    }

    func processStartIdentity(for _: Int32) -> UInt64? {
        self.liveProcessStartIdentity
    }
}

@MainActor
private final class ExactWindowApplicationService: ApplicationServiceProtocol {
    let app: ServiceApplicationInfo
    let windows: [ServiceWindowInfo]
    var listApplicationsCalls = 0
    var findApplicationCalls = 0
    var listWindowsCalls = 0

    init(app: ServiceApplicationInfo, windows: [ServiceWindowInfo]) {
        self.app = app
        self.windows = windows
    }

    func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData> {
        self.listApplicationsCalls += 1
        return UnifiedToolOutput(
            data: ServiceApplicationListData(applications: [self.app]),
            summary: .init(brief: "apps", status: .success),
            metadata: .init(duration: 0))
    }

    func findApplication(identifier _: String) async throws -> ServiceApplicationInfo {
        self.findApplicationCalls += 1
        return self.app
    }

    func listWindows(for _: String, timeout _: Float?) async throws -> UnifiedToolOutput<ServiceWindowListData> {
        self.listWindowsCalls += 1
        return UnifiedToolOutput(
            data: ServiceWindowListData(windows: self.windows, targetApplication: self.app),
            summary: .init(brief: "windows", status: .success),
            metadata: .init(duration: 0))
    }

    func getFrontmostApplication() async throws -> ServiceApplicationInfo {
        self.app
    }

    func isApplicationRunning(identifier _: String) async -> Bool {
        true
    }

    func launchApplication(identifier _: String) async throws -> ServiceApplicationInfo {
        self.app
    }

    func activateApplication(identifier _: String) async throws {}
    func quitApplication(identifier _: String, force _: Bool) async throws -> Bool {
        true
    }

    func hideApplication(identifier _: String) async throws {}
    func unhideApplication(identifier _: String) async throws {}
    func hideOtherApplications(identifier _: String) async throws {}
    func showAllApplications() async throws {}
}
