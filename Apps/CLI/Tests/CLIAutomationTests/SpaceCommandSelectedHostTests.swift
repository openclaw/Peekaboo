import Commander
import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooAutomation
@testable import PeekabooCLI
@testable import PeekabooCore

@Suite(.tags(.safe), .serialized)
@MainActor
struct SpaceCommandSelectedHostTests {
    @Test
    func `local Space move emits canonical JSON outcome and exact target receipt`() async throws {
        let window = Self.exactWindow()
        let windows = StubWindowService(windowsByApp: ["Fixture": [window]])
        let applications = StubApplicationService(applications: [Self.exactApplication()])
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            windows: windows
        )
        let spaceService = ExactReceiptSpaceCommandService(
            spaces: [Self.spaceInfo],
            liveWindow: window
        )

        let result = try await InProcessCommandRunner.run(
            ["space", "move-window", "--app", "Fixture", "--to-current", "--json"],
            services: services,
            spaceService: spaceService
        )

        #expect(result.exitStatus == 0)
        let response = try JSONDecoder().decode(
            CodableJSONResponse<WindowSpaceActionResult>.self,
            from: Data(result.combinedOutput.utf8)
        )
        #expect(response.success)
        #expect(response.outcome?.state == .dispatchedUnverified)
        #expect(response.outcome?.dispatchState.unitCount == .one)
        #expect(response.outcome?.retrySafe == false)
        #expect(response.target_receipt == DesktopActionTargetReceipt(
            processIdentifier: 777,
            processStartIdentity: 70,
            windowID: 99
        ))
        #expect(response.target_identity?.kind == .window)
        #expect(response.target_identity?.pid == 777)
        #expect(response.target_identity?.process_start_identity_decimal == "70")
        #expect(response.target_identity?.window_id == 99)
        #expect(spaceService.moveToCurrentCalls == [99])
    }

    @Test(arguments: [true, false])
    func `local Space move refuses same-ID generation or bounds replacement before dispatch`(
        replaceGeneration: Bool
    ) async throws {
        let selectedWindow = Self.exactWindow()
        let liveWindow = Self.exactWindow(
            processGeneration: replaceGeneration ? 71 : 70,
            bounds: replaceGeneration
                ? selectedWindow.bounds
                : CGRect(x: 120, y: 100, width: 700, height: 500)
        )
        let windows = StubWindowService(windowsByApp: ["Fixture": [selectedWindow]])
        let applications = StubApplicationService(applications: [Self.exactApplication()])
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            windows: windows
        )
        let spaceService = ExactReceiptSpaceCommandService(
            spaces: [Self.spaceInfo],
            liveWindow: liveWindow
        )

        let result = try await InProcessCommandRunner.run(
            ["space", "move-window", "--app", "Fixture", "--to-current", "--json"],
            services: services,
            spaceService: spaceService
        )

        #expect(result.exitStatus == 1)
        let response = try JSONDecoder().decode(
            JSONResponse.self,
            from: Data(result.combinedOutput.utf8)
        )
        #expect(!response.success)
        #expect(response.outcome?.state == .refused)
        #expect(response.outcome?.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(response.outcome?.retrySafe == true)
        #expect(response.error?.mutation_dispatched == false)
        #expect(response.error?.retry_safe == true)
        #expect(response.target_receipt == DesktopActionTargetReceipt(
            processIdentifier: 777,
            processStartIdentity: 70,
            windowID: 99
        ))
        #expect(spaceService.identityValidationCount == 1)
        #expect(spaceService.moveToCurrentCalls.isEmpty)
    }

    @Test
    func `local Space app title and index selectors reject a window owned by another process`() async throws {
        let selectedWindow = Self.exactWindow()
        let windows = StubWindowService(windowsByApp: ["Fixture": [selectedWindow]])
        let applications = StubApplicationService(applications: [
            Self.exactApplication(processIdentifier: 778, processGeneration: 80),
        ])
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            windows: windows
        )
        let spaceService = ExactReceiptSpaceCommandService(
            spaces: [Self.spaceInfo],
            liveWindow: selectedWindow
        )
        let selectors: [[String]] = [
            [],
            ["--window-title", "Exact Window"],
            ["--window-index", "0"],
        ]

        for selector in selectors {
            let result = try await InProcessCommandRunner.run(
                ["space", "move-window", "--app", "Fixture"] + selector + ["--to-current", "--json"],
                services: services,
                spaceService: spaceService
            )
            #expect(result.exitStatus == 1)
            let response = try JSONDecoder().decode(
                JSONResponse.self,
                from: Data(result.combinedOutput.utf8)
            )
            #expect(response.outcome?.state == .refused)
            #expect(response.error?.mutation_dispatched == false)
        }
        #expect(spaceService.identityValidationCount == 0)
        #expect(spaceService.moveToCurrentCalls.isEmpty)
    }

    @Test
    func `remote ownership errors distinguish reads from canonical mutation refusals`() throws {
        let services = RemoteSelectedHostServices(base: TestServicesFactory.makePeekabooServices())

        let readError = #expect(throws: RemoteSpaceReadUnsupportedError.self) {
            try SpaceCommandHostOwnership.requireLocalRead(
                services: services,
                operation: "list Spaces"
            )
        }
        #expect(readError?.envelopeCode == .BRIDGE_UNAVAILABLE)
        #expect(readError?.envelopeEffect == nil)
        #expect(readError?.envelopeRetrySafe == nil)
        #expect(readError?.envelopeMutationDispatched == nil)
        #expect(readError?.localizedDescription.contains("remote Space support is not implemented") == true)

        let mutationError = #expect(throws: PreDispatchActionError.self) {
            try SpaceCommandHostOwnership.requireLocalMutation(
                services: services,
                operation: "switch Spaces"
            )
        }
        let outcome = mutationError?.failure.outcome
        #expect(mutationError?.envelopeCode == .BRIDGE_UNAVAILABLE)
        #expect(outcome?.state == .refused)
        #expect(outcome?.refusalReason == .operationUnsupported)
        #expect(outcome?.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(outcome?.retrySafety == .safe)

        let refusal = try #require(mutationError)
        let metadata = actionErrorEnvelopeMetadata(for: refusal, isActionCommand: true)
        let envelope = ResultEnvelopeContext.$isActionCommand.withValue(true) {
            makeErrorEnvelope(
                message: refusal.localizedDescription,
                code: refusal.code,
                hint: refusal.hint,
                effect: metadata.effect,
                retrySafe: metadata.retrySafe,
                mutationDispatched: metadata.mutationDispatched,
                actionFailure: metadata.failure
            )
        }
        #expect(envelope.effect == .refused)
        #expect(envelope.error?.retry_safe == true)
        #expect(envelope.error?.mutation_dispatched == false)
    }

    @Test
    func `remote Space commands refuse before caller-local inventory or exact window discovery`() async throws {
        let spaceService = RecordingSpaceCommandService(spaces: [Self.spaceInfo])
        let windowService = RecordingSpaceWindowService(windowsByApp: [
            "RemoteApp": [Self.remoteWindow],
        ])
        let base = TestServicesFactory.makePeekabooServices(windows: windowService)
        let tracker = InteractionMutationTracker()
        let runtime = self.makeRuntime(
            services: RemoteSelectedHostServices(base: base),
            tracker: tracker
        )

        var list = try ListSubcommand.parse(["--detailed"])
        await #expect(throws: ExitCode.self) {
            try await SpaceCommandEnvironment.withSpaceService(spaceService) {
                try await list.run(using: runtime)
            }
        }

        var switchSpace = try SwitchSubcommand.parse(["--to", "1", "--foreground"])
        await #expect(throws: ExitCode.self) {
            try await SpaceCommandEnvironment.withSpaceService(spaceService) {
                try await switchSpace.run(using: runtime)
            }
        }

        var move = try MoveWindowSubcommand.parse(["--app", "RemoteApp", "--to", "1"])
        await #expect(throws: ExitCode.self) {
            try await SpaceCommandEnvironment.withSpaceService(spaceService) {
                try await move.run(using: runtime)
            }
        }

        #expect(spaceService.getAllSpacesCalls == 0)
        #expect(spaceService.getSpacesForWindowCalls == 0)
        #expect(spaceService.switchCalls.isEmpty)
        #expect(spaceService.moveWindowCalls.isEmpty)
        #expect(spaceService.moveToCurrentCalls.isEmpty)
        #expect(windowService.listWindowsCalls == 0)
        #expect(tracker.mutationStartedAt == nil)
    }

    @Test
    func `local selected host preserves Space mutation behavior`() async throws {
        let spaceService = RecordingSpaceCommandService(spaces: [Self.spaceInfo])
        let services = TestServicesFactory.makePeekabooServices()
        let tracker = InteractionMutationTracker()
        let runtime = self.makeRuntime(services: services, tracker: tracker)
        var command = try SwitchSubcommand.parse(["--to", "1", "--foreground"])

        try await SpaceCommandEnvironment.withSpaceService(spaceService) {
            try await command.run(using: runtime)
        }

        #expect(spaceService.getAllSpacesCalls == 1)
        #expect(spaceService.switchCalls == [Self.spaceInfo.id])
        #expect(tracker.mutationStartedAt != nil)
    }

    @Test
    func `Space switch refuses without foreground consent before inventory or dispatch`() async throws {
        let spaceService = RecordingSpaceCommandService(spaces: [Self.spaceInfo])
        let services = TestServicesFactory.makePeekabooServices()

        let result = try await InProcessCommandRunner.run(
            ["space", "switch", "--to", "1", "--json"],
            services: services,
            spaceService: spaceService
        )

        #expect(result.exitStatus == 1)
        let response = try JSONDecoder().decode(JSONResponse.self, from: Data(result.combinedOutput.utf8))
        #expect(response.outcome?.state == .refused)
        #expect(response.outcome?.refusalReason == .foregroundConsentRequired)
        #expect(response.error?.mutation_dispatched == false)
        #expect(response.error?.retry_safe == true)
        #expect(spaceService.getAllSpacesCalls == 0)
        #expect(spaceService.switchCalls.isEmpty)
    }

    @Test
    func `Space move follow refuses without foreground consent before target discovery`() async throws {
        let spaceService = RecordingSpaceCommandService(spaces: [Self.spaceInfo])
        let windowService = RecordingSpaceWindowService(windowsByApp: [
            "Fixture": [Self.exactWindow()],
        ])
        let services = TestServicesFactory.makePeekabooServices(windows: windowService)

        let result = try await InProcessCommandRunner.run(
            ["space", "move-window", "--window-id", "99", "--to", "1", "--follow", "--json"],
            services: services,
            spaceService: spaceService
        )

        #expect(result.exitStatus == 1)
        let response = try JSONDecoder().decode(JSONResponse.self, from: Data(result.combinedOutput.utf8))
        #expect(response.outcome?.state == .refused)
        #expect(response.outcome?.refusalReason == .foregroundConsentRequired)
        #expect(response.error?.mutation_dispatched == false)
        #expect(response.error?.retry_safe == true)
        #expect(windowService.listWindowsCalls == 0)
        #expect(spaceService.getAllSpacesCalls == 0)
        #expect(spaceService.moveWindowCalls.isEmpty)
        #expect(spaceService.switchCalls.isEmpty)
    }

    private func makeRuntime(
        services: any PeekabooServiceProviding,
        tracker: InteractionMutationTracker
    ) -> CommandRuntime {
        CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: false,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: services,
            interactionMutationTracker: tracker
        )
    }

    private static let spaceInfo = SpaceInfo(
        id: 41,
        type: .user,
        isActive: true,
        displayID: 1,
        name: "Desktop 1",
        ownerPIDs: [101]
    )

    private static let remoteWindow = ServiceWindowInfo(
        windowID: 99,
        title: "Remote Window",
        bounds: CGRect(x: 100, y: 100, width: 700, height: 500),
        isMinimized: false,
        isMainWindow: true,
        windowLevel: 0,
        alpha: 1.0,
        index: 0,
        spaceID: 41,
        spaceName: "Remote Desktop",
        screenIndex: 0,
        screenName: "Remote Display"
    )

    private static func exactWindow(
        processGeneration: UInt64 = 70,
        bounds: CGRect = CGRect(x: 100, y: 100, width: 700, height: 500)
    ) -> ServiceWindowInfo {
        ServiceWindowInfo(
            windowID: 99,
            title: "Exact Window",
            bounds: bounds,
            isMainWindow: true,
            index: 0,
            mutationIdentity: WindowMutationIdentity(
                windowID: 99,
                ownerProcessIdentifier: 777,
                ownerProcessStartIdentity: processGeneration,
                capturedBounds: bounds
            )
        )
    }

    private static func exactApplication(
        processIdentifier: Int32 = 777,
        processGeneration: UInt64 = 70
    ) -> ServiceApplicationInfo {
        ServiceApplicationInfo(
            processIdentifier: processIdentifier,
            processStartIdentity: processGeneration,
            bundleIdentifier: "com.example.Fixture",
            name: "Fixture"
        )
    }
}

@MainActor
private final class ExactReceiptSpaceCommandService: SpaceCommandSpaceService {
    let spaces: [SpaceInfo]
    var liveWindow: ServiceWindowInfo
    private(set) var identityValidationCount = 0
    private(set) var moveToCurrentCalls: [CGWindowID] = []
    private(set) var moveWindowCalls: [(windowID: CGWindowID, spaceID: CGSSpaceID)] = []

    init(spaces: [SpaceInfo], liveWindow: ServiceWindowInfo) {
        self.spaces = spaces
        self.liveWindow = liveWindow
    }

    func getAllSpaces() async -> [SpaceInfo] {
        self.spaces
    }

    func getSpacesForWindow(windowID _: CGWindowID) async -> [SpaceInfo] {
        self.spaces
    }

    func moveWindowToCurrentSpaceResult(
        windowID: CGWindowID,
        expectedIdentity: WindowMutationIdentity
    ) async throws -> UIAutomationActionResult<Void> {
        let result = try self.validateAndMakeResult(
            windowID: windowID,
            expectedIdentity: expectedIdentity
        )
        self.moveToCurrentCalls.append(windowID)
        return result
    }

    func moveWindowToSpaceResult(
        windowID: CGWindowID,
        expectedIdentity: WindowMutationIdentity,
        spaceID: CGSSpaceID
    ) async throws -> UIAutomationActionResult<Void> {
        let result = try self.validateAndMakeResult(
            windowID: windowID,
            expectedIdentity: expectedIdentity
        )
        self.moveWindowCalls.append((windowID, spaceID))
        return result
    }

    func switchToSpaceResult(_: CGSSpaceID) async throws -> DesktopActionResult<Void> {
        DesktopActionResult(outcome: .confirmedNoChange())
    }

    private func validateAndMakeResult(
        windowID: CGWindowID,
        expectedIdentity: WindowMutationIdentity
    ) throws -> UIAutomationActionResult<Void> {
        self.identityValidationCount += 1
        let targetReceipt = DesktopActionTargetReceipt(
            processIdentifier: expectedIdentity.ownerProcessIdentifier,
            processStartIdentity: expectedIdentity.ownerProcessStartIdentity,
            windowID: expectedIdentity.windowID
        )
        guard Int(windowID) == expectedIdentity.windowID,
              let liveIdentity = self.liveWindow.mutationIdentity,
              liveIdentity.hasSameStableReceipt(as: expectedIdentity),
              expectedIdentity.capturedBounds == self.liveWindow.bounds,
              liveIdentity.capturedBounds == self.liveWindow.bounds
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Space move target changed before dispatch.",
                hint: "Refresh the window inventory before retrying."
            )
            .attributed(to: targetReceipt)
        }
        return try UIAutomationActionResult(
            payload: (),
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .nativeFramework, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one
            ),
            targetIdentity: DesktopTargetIdentity(
                exactWindow: UIAutomationTarget.ExactWindow(
                    identity: expectedIdentity,
                    bounds: self.liveWindow.bounds
                )
            )
        )
    }
}

@MainActor
private final class RecordingSpaceCommandService: SpaceCommandSpaceService {
    let spaces: [SpaceInfo]
    private(set) var getAllSpacesCalls = 0
    private(set) var getSpacesForWindowCalls = 0
    private(set) var switchCalls: [CGSSpaceID] = []
    private(set) var moveWindowCalls: [(windowID: CGWindowID, spaceID: CGSSpaceID)] = []
    private(set) var moveToCurrentCalls: [CGWindowID] = []

    init(spaces: [SpaceInfo]) {
        self.spaces = spaces
    }

    func getAllSpaces() async -> [SpaceInfo] {
        self.getAllSpacesCalls += 1
        return self.spaces
    }

    func getSpacesForWindow(windowID _: CGWindowID) async -> [SpaceInfo] {
        self.getSpacesForWindowCalls += 1
        return self.spaces
    }

    func moveWindowToCurrentSpaceResult(
        windowID: CGWindowID,
        expectedIdentity: WindowMutationIdentity
    ) async throws -> UIAutomationActionResult<Void> {
        self.moveToCurrentCalls.append(windowID)
        return try Self.result(expectedIdentity: expectedIdentity)
    }

    func moveWindowToSpaceResult(
        windowID: CGWindowID,
        expectedIdentity: WindowMutationIdentity,
        spaceID: CGSSpaceID
    ) async throws -> UIAutomationActionResult<Void> {
        self.moveWindowCalls.append((windowID, spaceID))
        return try Self.result(expectedIdentity: expectedIdentity)
    }

    func switchToSpaceResult(_ spaceID: CGSSpaceID) async throws -> DesktopActionResult<Void> {
        self.switchCalls.append(spaceID)
        return DesktopActionResult(
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one
            )
        )
    }

    private static func result(
        expectedIdentity: WindowMutationIdentity
    ) throws -> UIAutomationActionResult<Void> {
        guard let bounds = expectedIdentity.capturedBounds else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Test Space target is missing exact bounds."
            )
        }
        return try UIAutomationActionResult(
            payload: (),
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .nativeFramework, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one
            ),
            targetIdentity: DesktopTargetIdentity(
                exactWindow: UIAutomationTarget.ExactWindow(
                    identity: expectedIdentity,
                    bounds: bounds
                )
            )
        )
    }
}

@MainActor
private final class RecordingSpaceWindowService: StubWindowService {
    private(set) var listWindowsCalls = 0

    override func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo] {
        self.listWindowsCalls += 1
        return try await super.listWindows(target: target)
    }
}

@MainActor
private final class RemoteSelectedHostServices: PeekabooServiceProviding {
    let executionHost: PeekabooServiceExecutionHost = .remote
    private let base: PeekabooServices

    init(base: PeekabooServices) {
        self.base = base
    }

    var logging: any LoggingServiceProtocol {
        self.base.logging
    }

    var desktopObservation: any DesktopObservationServiceProtocol {
        self.base.desktopObservation
    }

    var screenCapture: any ScreenCaptureServiceProtocol {
        self.base.screenCapture
    }

    var applications: any ApplicationServiceProtocol {
        self.base.applications
    }

    var automation: any UIAutomationServiceProtocol {
        self.base.automation
    }

    var windows: any WindowManagementServiceProtocol {
        self.base.windows
    }

    var menu: any MenuServiceProtocol {
        self.base.menu
    }

    var dock: any DockServiceProtocol {
        self.base.dock
    }

    var dialogs: any DialogServiceProtocol {
        self.base.dialogs
    }

    var snapshots: any SnapshotManagerProtocol {
        self.base.snapshots
    }

    var files: any FileServiceProtocol {
        self.base.files
    }

    var clipboard: any ClipboardServiceProtocol {
        self.base.clipboard
    }

    var configuration: PeekabooAutomation.ConfigurationManager {
        self.base.configuration
    }

    var permissions: PermissionsService {
        self.base.permissions
    }

    var audioInput: AudioInputService {
        self.base.audioInput
    }

    var screens: any ScreenServiceProtocol {
        self.base.screens
    }

    var browser: any BrowserMCPClientProviding {
        self.base.browser
    }

    var agent: (any AgentServiceProtocol)? {
        self.base.agent
    }

    func ensureVisualizerConnection() {}
}
