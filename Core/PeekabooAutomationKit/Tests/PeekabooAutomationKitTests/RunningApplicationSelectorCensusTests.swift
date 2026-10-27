import AppKit
import CoreGraphics
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable @_spi(Testing) import PeekabooAutomationKit

@Suite(.serialized)
@MainActor
struct RunningApplicationSelectorCensusTests {
    @Test(arguments: [false, true])
    func `unresolved contenders remain ambiguous across capture discovery and running state`(
        reversed: Bool) async throws
    {
        let applications = SelectorCensusTestFixture.thirdContenderApplications(reversed: reversed)
        let service = SelectorCensusTestFixture.service(applications: applications)
        let capture = SelectorCensusTestFixture.captureResolver(applications: applications)
        for identifier in ["Fixture", "com.example.selector-census", "/Applications/Fixture.app", "fixture-runner"] {
            await #expect(throws: PeekabooError.self) { _ = try await service.findApplication(identifier: identifier) }
            await #expect(throws: PeekabooError.self) { _ = try await capture.findApplication(identifier: identifier) }
            do {
                _ = try await service.isApplicationRunning(identifier: identifier)
                Issue.record("An incomplete PID census must not establish a unique running match")
            } catch let error as PeekabooError {
                guard case let .ambiguousAppIdentifier(_, suggestions) = error else { throw error }
                #expect(suggestions.count == 3)
                #expect(suggestions.filter { $0.contains("process identity unavailable") }.count == 2)
                #expect(!suggestions.contains { $0.contains("PID:-1") })
            }
        }
    }

    @Test
    func `unresolved exact winner never falls through to a resolved fuzzy match`() async throws {
        let applications = [
            SelectorCensusRunningApplication(),
            SelectorCensusRunningApplication(processIdentifier: 64002, name: "Fixture Preview"),
        ]
        let service = SelectorCensusTestFixture.service(applications: applications)
        let capture = SelectorCensusTestFixture.captureResolver(applications: applications)
        await #expect(throws: PeekabooError.self) { _ = try await service.findApplication(identifier: "Fixture") }
        await #expect(throws: PeekabooError.self) { _ = try await capture.findApplication(identifier: "Fixture") }
        #expect(try await service.isApplicationRunning(identifier: "Fixture"))
    }

    @Test
    func `unresolved fuzzy contender retains the shared score and tie`() throws {
        let applications = [
            SelectorCensusRunningApplication(name: "Fixture Alpha"),
            SelectorCensusRunningApplication(processIdentifier: 64002, name: "Fixture Bravo"),
        ]
        let census = RunningApplicationSelectorCensus(
            applications: applications,
            processIdentifierResolver: SelectorCensusTestFixture.processIdentifier)
        let resolution = try #require(try ApplicationIdentifierMatcher.resolution(
            for: "Fixture", in: census.candidates))
        #expect(resolution.matchKind == .fuzzyNameOrExecutable)
        #expect(resolution.hasWinningTie)
        #expect(throws: PeekabooError.self) { _ = try census.resolve(identifier: "Fixture") }
    }

    @Test
    func `unrelated unresolved descriptors retain proof census without blocking verified targets`() async throws {
        let applications = [
            SelectorCensusRunningApplication(name: "Unrelated", bundleIdentifier: "com.example.unrelated"),
            SelectorCensusRunningApplication(processIdentifier: 64002),
        ]
        let service = SelectorCensusTestFixture.service(applications: applications)
        for identifier in ["Fixture", "PID:64002"] {
            let application = try await service.findApplication(identifier: identifier)
            let proof = try #require(application.selectorResolutionProofs?.first)
            #expect(application.processIdentifier == 64002)
            #expect(proof.candidateCount == 2)
            #expect(!proof.hasWinningTie)
        }
        let census = RunningApplicationSelectorCensus(
            applications: applications,
            processIdentifierResolver: SelectorCensusTestFixture.processIdentifier)
        let reversed = RunningApplicationSelectorCensus(
            applications: Array(applications.reversed()),
            processIdentifierResolver: SelectorCensusTestFixture.processIdentifier)
        #expect(try census.resolve(identifier: "Fixture").resolution.candidateSetSHA256 ==
            reversed.resolve(identifier: "Fixture").resolution.candidateSetSHA256)
    }

    @Test
    func `unique unresolved descriptor exists without supplying a dispatch identity`() async throws {
        let applications = [SelectorCensusRunningApplication()]
        let service = SelectorCensusTestFixture.service(applications: applications)
        #expect(try await service.isApplicationRunning(identifier: "Fixture"))
        #expect(try await !(service.isApplicationRunning(identifier: "Missing")))
        await #expect(throws: PeekabooError.self) { _ = try await service.findApplication(identifier: "Fixture") }
        for identifier in ["PID:-1", "PID:0"] {
            #expect(try await !(service.isApplicationRunning(identifier: identifier)))
            await #expect(throws: PeekabooError.self) { _ = try await service.findApplication(identifier: identifier) }
        }
    }

    @Test
    func `successful identity recovery and terminated exclusion retain their contracts`() throws {
        let census = RunningApplicationSelectorCensus(
            applications: [SelectorCensusRunningApplication(), SelectorCensusRunningApplication(terminated: true)],
            processIdentifierResolver: { _ in 64001 })
        let selected = try census.resolve(identifier: "PID:64001")
        #expect(selected.application.processIdentifier == -1)
        #expect(selected.processIdentifier == 64001)
        #expect(selected.resolution.candidateCount == 1)
        #expect(census.inventorySeed.omissionWarnings.isEmpty)
    }

    @Test
    func `unresolved descriptors remain inside the existing proof bound`() {
        let census = RunningApplicationSelectorCensus(
            applications: (0...ApplicationIdentifierMatcher.maximumProofCandidateCount).map { _ in
                SelectorCensusRunningApplication()
            },
            processIdentifierResolver: { _ in nil })
        #expect(throws: ApplicationIdentifierMatcher.ResolutionError.self) {
            _ = try census.resolve(identifier: "Fixture")
        }
    }

    @Test
    func `both inventories expose unresolved omissions and mutation planning retains ambiguity`() async throws {
        let service = SelectorCensusTestFixture.service(
            applications: SelectorCensusTestFixture.thirdContenderApplications())
        let listing = try await service.listApplications()
        let inventory = try await service.applicationMutationInventory()
        #expect(listing.summary.status == .partial)
        #expect(listing.summary.counts["omittedApplications"] == 2)
        #expect(listing.data.applications.map(\.processIdentifier) == [64002])
        #expect(!inventory.isComplete)
        #expect(inventory.items.map(\.processIdentifier) == [64002])
        #expect(inventory.warnings.count == 2)
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(applications: service)
        for identifier in ["Fixture", "com.example.selector-census"] {
            await #expect(throws: DesktopTargetPlanningError.ambiguousApplication(
                identifier: identifier, candidatePIDs: []))
            {
                _ = try await planner.plan(identifier: identifier)
            }
        }
        let exact = try await planner.plan(identifier: "PID:64002")
        #expect(exact.processIdentity.processIdentifier == 64002)
    }

    @Test
    func `unrelated unresolved inventory rows still allow authoritative mutation planning`() async throws {
        let service = SelectorCensusTestFixture.service(applications: [
            SelectorCensusRunningApplication(name: "Unrelated", bundleIdentifier: "com.example.unrelated"),
            SelectorCensusRunningApplication(processIdentifier: 64002),
        ])
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(applications: service)
        let plan = try await planner.plan(identifier: "Fixture")
        #expect(plan.processIdentity.processIdentifier == 64002)
        #expect(plan.selectorProof.candidateCount == 2)
    }

    @Test(arguments: SelectorCensusMutationAction.allCases)
    func `unresolved selectors dispatch no mutations while verified controls reach the spies`(
        action: SelectorCensusMutationAction) async throws
    {
        let pid = ProcessInfo.processInfo.processIdentifier
        _ = try #require(NSRunningApplication(processIdentifier: pid))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: directory)
        var dispatches: [SelectorCensusMutationAction] = []
        func service(_ applications: [NSRunningApplication]) -> ApplicationService {
            ApplicationService(
                operationLaneCoordinator: coordinator,
                applicationOpenHandler: { _, _, _ in throw PeekabooError.notImplemented("Unused launch") },
                processStartIdentityProvider: { _ in 10 },
                applicationQuitHandler: { _, force in
                    dispatches.append(force ? .forceQuit : .quit)
                    return false
                },
                applicationHiddenProvider: { _ in action == .unhide },
                applicationVisibilityHandler: { _, hidden in
                    dispatches.append(hidden ? .hide : .unhide)
                    return false
                },
                runningApplicationsProvider: { applications },
                applicationProcessIdentifierResolver: SelectorCensusTestFixture.processIdentifier)
        }
        let tied = service([
            SelectorCensusRunningApplication(),
            SelectorCensusRunningApplication(),
            SelectorCensusRunningApplication(processIdentifier: pid),
        ])
        for identifier in ["Fixture", "com.example.selector-census"] {
            do {
                try await action.invoke(tied, identifier: identifier)
                Issue.record("Ambiguous mutation unexpectedly completed")
            } catch let error as PeekabooError {
                guard case let .ambiguousAppIdentifier(_, suggestions) = error else { throw error }
                #expect(suggestions.count == 3)
            }
            #expect(dispatches.isEmpty)
        }
        // The positive control uses the same real PID and generation path. A fake or missing
        // process cannot make the zero-dispatch assertion pass by failing before a reachable spy.
        await #expect(throws: DesktopActionFailure.self) {
            try await action.invoke(tied, identifier: "PID:\(pid)")
        }
        #expect(dispatches == [action])
        dispatches.removeAll()

        let higherPrecedence = service([
            SelectorCensusRunningApplication(),
            SelectorCensusRunningApplication(processIdentifier: pid, name: "Fixture Preview"),
        ])
        let unresolved = service([SelectorCensusRunningApplication()])
        for refused in [higherPrecedence, unresolved] {
            do {
                try await action.invoke(refused, identifier: "Fixture")
                Issue.record("Unverified mutation unexpectedly completed")
            } catch let error as PeekabooError {
                guard case .commandFailed = error else { throw error }
            }
            #expect(dispatches.isEmpty)
        }
        let unrelated = service([
            SelectorCensusRunningApplication(name: "Unrelated", bundleIdentifier: "com.example.unrelated"),
            SelectorCensusRunningApplication(processIdentifier: pid),
        ])
        await #expect(throws: DesktopActionFailure.self) {
            try await action.invoke(unrelated, identifier: "Fixture")
        }
        #expect(dispatches == [action])
    }

    @Test
    func `ambiguous third contender reaches no capture backend while exact PID does`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = SelectorCensusCaptureOperator()
        let dependencies = ScreenCaptureService.Dependencies(
            feedbackClient: NoopAutomationFeedbackClient(),
            permissionEvaluator: SelectorCensusCapturePermission(),
            fallbackRunner: ScreenCaptureFallbackRunner(apis: [.legacy]),
            applicationResolver: SelectorCensusTestFixture.captureResolver(
                applications: SelectorCensusTestFixture.thirdContenderApplications()),
            makeFrameSource: { _ in SelectorCensusFrameSource() },
            makeModernOperator: { _, _ in backend },
            makeLegacyOperator: { _ in backend },
            screenLockProbe: { false })
        let service = ScreenCaptureService(loggingService: MockLoggingService(), dependencies: dependencies)
        try await ScreenCaptureService.withIsolatedCaptureCoordination(directory: directory) {
            await #expect(throws: PeekabooError.self) {
                _ = try await service.captureWindow(appIdentifier: "Fixture", windowIndex: nil)
            }
            #expect(backend.attempts == 0)
            await #expect(throws: PeekabooError.self) {
                _ = try await service.captureWindow(appIdentifier: "PID:64002", windowIndex: nil)
            }
            #expect(backend.attempts == 1)
        }
    }
}

enum SelectorCensusMutationAction: CaseIterable, Sendable {
    case quit
    case forceQuit
    case hide
    case unhide

    @MainActor
    func invoke(_ service: ApplicationService, identifier: String) async throws {
        switch self {
        case .quit, .forceQuit:
            _ = try await service.quitApplicationActionResult(request: .init(
                identifier: identifier,
                force: self == .forceQuit))
        case .hide:
            _ = try await service.hideApplicationActionResult(identifier: identifier)
        case .unhide:
            _ = try await service.unhideApplicationActionResult(identifier: identifier)
        }
    }
}

enum SelectorCensusTestFixture {
    static func thirdContenderApplications(reversed: Bool = false) -> [NSRunningApplication] {
        let applications: [NSRunningApplication] = [
            SelectorCensusRunningApplication(),
            SelectorCensusRunningApplication(),
            SelectorCensusRunningApplication(processIdentifier: 64002),
        ]
        return reversed ? Array(applications.reversed()) : applications
    }

    static func processIdentifier(_ application: NSRunningApplication) -> pid_t? {
        application.processIdentifier > 0 ? application.processIdentifier : nil
    }

    static func captureResolver(applications: [NSRunningApplication]) -> PeekabooApplicationResolver {
        PeekabooApplicationResolver(
            runningApplicationsProvider: { applications },
            processIdentifierResolver: self.processIdentifier)
    }

    @MainActor
    static func service(applications: [NSRunningApplication]) -> ApplicationService {
        ApplicationService(
            applicationOpenHandler: { _, _, _ in throw PeekabooError.notImplemented("Unused launch") },
            applicationMutationCandidateProvider: { pid in
                applications.first { $0.processIdentifier == pid }.map {
                    RunningApplicationSelectorCensus.Entry($0).candidate
                }
            },
            frontmostProcessIdentifierProvider: { nil },
            processStartIdentityProvider: { _ in 10 },
            mutationIdentityObservationProvider: { _ in .identity(10) },
            runningApplicationsProvider: { applications },
            applicationProcessIdentifierResolver: self.processIdentifier,
            applicationWindowCatalogProvider: { [] },
            applicationMetadataProvider: { pid, _, _ in
                let application = applications.first { $0.processIdentifier == pid }
                return DetachedApplicationMetadata(
                    bundleIdentifier: application?.bundleIdentifier,
                    name: application?.localizedName,
                    bundlePath: application?.bundleURL?.path,
                    isHidden: false,
                    activationPolicy: .regular,
                    isFinishedLaunching: true)
            },
            applicationInventoryWorker: DetachedApplicationInventoryWorker())
    }
}

final class SelectorCensusRunningApplication: NSRunningApplication, @unchecked Sendable {
    private let fixturePID: pid_t
    private let fixtureName: String
    private let fixtureBundleIdentifier: String
    private let fixtureBundlePath: String
    private let fixtureExecutablePath: String
    private let fixtureTerminated: Bool

    init(
        processIdentifier: pid_t = -1,
        name: String = "Fixture",
        bundleIdentifier: String = "com.example.selector-census",
        bundlePath: String = "/Applications/Fixture.app",
        executablePath: String = "/Applications/Fixture.app/Contents/MacOS/fixture-runner",
        terminated: Bool = false)
    {
        self.fixturePID = processIdentifier
        self.fixtureName = name
        self.fixtureBundleIdentifier = bundleIdentifier
        self.fixtureBundlePath = bundlePath
        self.fixtureExecutablePath = executablePath
        self.fixtureTerminated = terminated
        super.init()
    }

    override var processIdentifier: pid_t {
        self.fixturePID
    }

    override var localizedName: String? {
        self.fixtureName
    }

    override var bundleIdentifier: String? {
        self.fixtureBundleIdentifier
    }

    override var bundleURL: URL? {
        URL(fileURLWithPath: self.fixtureBundlePath)
    }

    override var executableURL: URL? {
        URL(fileURLWithPath: self.fixtureExecutablePath)
    }

    override var isTerminated: Bool {
        self.fixtureTerminated
    }

    override var isActive: Bool {
        false
    }

    override var isHidden: Bool {
        false
    }

    override var isFinishedLaunching: Bool {
        true
    }

    override var activationPolicy: NSApplication.ActivationPolicy {
        .regular
    }
}

struct SelectorCensusCapturePermission: ScreenRecordingPermissionEvaluating {
    func hasPermission(logger _: CategoryLogger, policy _: ScreenRecordingPermissionProbePolicy) async -> Bool {
        true
    }
}

struct SelectorCensusFrameSource: CaptureFrameSource {
    @MainActor
    func nextFrame() async throws -> (cgImage: CGImage?, metadata: CaptureMetadata)? {
        nil
    }
}

@MainActor
final class SelectorCensusCaptureOperator: ModernScreenCaptureOperating, LegacyScreenCaptureOperating {
    private(set) var attempts = 0

    func captureScreen(
        displayIndex _: Int?,
        correlationId _: String,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        try self.unexpectedCapture()
    }

    func captureWindow(
        app _: ServiceApplicationInfo,
        windowIndex _: Int?,
        correlationId _: String,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        try self.unexpectedCapture()
    }

    func captureWindow(
        windowID _: CGWindowID,
        correlationId _: String,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        try self.unexpectedCapture()
    }

    func captureArea(
        _: CGRect, correlationId _: String, scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        try self.unexpectedCapture()
    }

    private func unexpectedCapture() throws -> CaptureResult {
        self.attempts += 1
        throw PeekabooError.notImplemented("Fixture capture backend")
    }
}
