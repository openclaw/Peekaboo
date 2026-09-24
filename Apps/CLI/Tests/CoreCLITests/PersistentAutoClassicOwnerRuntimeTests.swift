import Commander
import Foundation
import MCP
import PeekabooAgentRuntime
import PeekabooAutomationKitTestSupport
import PeekabooBridge
import PeekabooBridgeTestSupport
import PeekabooCore
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooCLI

extension ScreenCaptureKitOwnerRuntimeTests {
    @Test(arguments: ["agent", "mcp"])
    func `persistent explicit host uses classic around a held owner and keeps per-call restrictions`(
        runtime: String
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("persistent-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("owner.lock")
        // Exercise the held-receipt branch using a real lock in a private namespace, never live SCK state.
        let child = try ScreenCaptureKitOwnerSubprocess(lockURL: lockURL)
        defer { child.stop() }
        let owner = try ScreenCaptureKitOwnerLease.OwnerReceipt(
            processIdentifier: child.process.processIdentifier,
            processStartIdentity: #require(SystemIdentityResolver
                .processStartIdentity(child.process.processIdentifier)),
            codeSignatureHash: "synthetic-owner"
        )
        try child.install(receipt: owner)
        #expect(try ScreenCaptureKitOwnerLease.currentOwnerReceiptIfHeld(lockURL: lockURL) == owner)
        let socket = Self.fixtureSocketPath()
        let observation = PersistentClassicObservationProbe()
        let host = try await Self.startPersistentClassicHost(socket: socket, observation: observation)
        defer { Task { await host.stop() } }
        var options = try CommanderCLIBinder.makeRuntimeOptions(
            from: .init(positional: [], options: ["bridge-socket": [socket]], flags: []),
            commandType: runtime == "agent" ? AgentRunSubcommand.self : MCPCommand.Serve.self
        )
        options.autoStartDaemon = false
        #expect(options.usesPersistentDynamicCaptureRuntime)
        var ownerInspections = 0
        var ownerClaims = 0
        var localFactories = 0
        let cache = RuntimeHostResolver.RemoteHandshakeCache(
            identity: .init(
                bundleIdentifier: "synthetic.persistent-capture",
                teamIdentifier: nil,
                processIdentifier: getpid()
            ),
            clientFactory: { BridgeTestFixtures.authenticatedClient(socketPath: $0) }
        )
        let resolution = try await RuntimeHostResolver.resolveServices(
            options: options,
            environment: [:],
            configurationInput: nil,
            dependencies: Self.inertDependencies(
                makeLocalServices: { _ in
                    localFactories += 1
                    return OwnerPolicyFixtureServices(ownerAware: true)
                },
                claimScreenCaptureKitOwner: {
                    ownerClaims += 1
                    return owner
                },
                inspectScreenCaptureKitOwner: {
                    ownerInspections += 1
                    return try ScreenCaptureKitOwnerLease.currentOwnerReceiptIfHeld(lockURL: lockURL)
                },
                makeRemoteHandshakeCache: { cache }
            )
        )
        #expect(resolution.selectedRemoteSocketPath == socket)
        #expect(resolution.selectedRemoteHostIdentity == .current())
        #expect(resolution.captureEngineSafetyOverride == .legacy)
        #expect(resolution.toolCapturePreflightRefusal == nil)
        #expect(ownerInspections == 1)
        #expect(ownerClaims == 0)
        #expect(localFactories == 0)

        for engine in [CaptureEnginePreference.auto, .legacy] {
            let error = await #expect(throws: DesktopActionFailure.self) {
                _ = try await resolution.services.desktopObservation.observe(Self.persistentCaptureRequest(engine))
            }
            #expect(error?.message.contains("persistent classic observation reached its exact host") == true)
        }
        #expect(observation.engines == [.legacy, .legacy])
        let modernFailure = await #expect(throws: DesktopActionFailure.self) {
            _ = try await resolution.services.desktopObservation.observe(Self.persistentCaptureRequest(.modern))
        }
        #expect(modernFailure?.screenCaptureKitOwnershipDiagnostic?.blockers.first?.processIdentifier ==
            owner.processIdentifier)
        #expect(modernFailure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(modernFailure?.outcome.retrySafety == .safe)
        #expect(observation.engines == [.legacy, .legacy])
        try await Self.expectRawCaptureRefusals(resolution.services.screenCapture)
        try await Self.expectToolCapturePolicy(services: resolution.services)
        #expect(observation.engines == Array(repeating: .legacy, count: 5))
        // The restriction is per service graph; an ordinary client still transports auto unchanged.
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: socket,
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        let entry = try #require(cache.entry(for: candidate, identity: cache.identity))
        #expect(entry.response.operationAttestation != nil)
        #expect(entry.response.operationSessionAttestation != nil)
        let unrestricted = RemoteDesktopObservationService(
            client: entry.client, supportsDesktopObservationCaptureEngine: true
        )
        _ = await #expect(throws: DesktopActionFailure.self) {
            _ = try await unrestricted.observe(Self.persistentCaptureRequest(.auto))
        }
        #expect(observation.engines == Array(repeating: .legacy, count: 5) + [.auto])

        await host.stop()
        let replacement = try await Self.startPersistentClassicHost(socket: socket, observation: observation)
        defer { Task { await replacement.stop() } }
        await #expect(throws: (any Error).self) {
            _ = try await resolution.services.desktopObservation.observe(Self.persistentCaptureRequest(.auto))
        }
        #expect(observation.engines == Array(repeating: .legacy, count: 5) + [.auto])
        await replacement.stop()
        try child.stopAndWait()
        #expect(try ScreenCaptureKitOwnerLease.currentOwnerReceiptIfHeld(lockURL: lockURL) == nil)
    }

    private static func persistentCaptureRequest(_ engine: CaptureEnginePreference) -> DesktopObservationRequest {
        DesktopObservationRequest(
            target: .windowID(77),
            capture: .init(engine: engine, focus: .background),
            detection: .init(mode: .none)
        )
    }

    private static func expectToolCapturePolicy(services: any PeekabooServiceProviding) async throws {
        let context = MCPToolContext(services: services)
        for engine in ["omitted", "auto", "modern"] {
            var arguments: [String: Value] = ["window_id": .int(77)]
            if engine != "omitted" {
                arguments["capture_engine"] = .string(engine)
            }
            let response = try await context.execute(
                tool: SeeTool(context: context), arguments: ToolArguments(value: .object(arguments))
            )
            #expect(response.isError)
            if engine == "modern" {
                #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(false))
                #expect(response.meta?.objectValue?["retry_safe"] == .bool(true))
            }
        }
        let image = try await context.execute(
            tool: ImageTool(context: context), arguments: ToolArguments(value: .object(["window_id": .int(77)]))
        )
        #expect(image.isError)
    }

    private static func startPersistentClassicHost(
        socket: String,
        observation: PersistentClassicObservationProbe
    ) async throws -> PeekabooBridgeHost {
        try await startHost(
            socketPath: socket,
            processIdentifier: getpid(),
            processStartIdentity: 1,
            codeSignatureHash: "unused-current-identity",
            maximumProtocolVersion: PeekabooBridgeConstants.protocolVersion,
            usesCurrentHostIdentity: true,
            serviceOverride: OwnerPolicyFixtureServices(ownerAware: true, observation: observation),
            windowIdentity: WindowMutationIdentity(
                windowID: 77,
                ownerProcessIdentifier: 3030,
                ownerProcessStartIdentity: 4040,
                capturedBounds: CGRect(x: 10, y: 20, width: 100, height: 80)
            )
        )
    }

    private static func expectRawCaptureRefusals(_ capture: any ScreenCaptureServiceProtocol) async throws {
        await #expect(throws: DesktopActionFailure.self) {
            _ = try await capture.captureScreen(displayIndex: 0, visualizerMode: .none, scale: .logical1x)
        }
        await #expect(throws: DesktopActionFailure.self) {
            _ = try await capture.captureWindow(
                appIdentifier: "synthetic", windowIndex: 0, visualizerMode: .none, scale: .logical1x
            )
        }
        await #expect(throws: DesktopActionFailure.self) {
            _ = try await capture.captureWindow(windowID: 77, visualizerMode: .none, scale: .logical1x)
        }
        await #expect(throws: DesktopActionFailure.self) {
            _ = try await capture.captureFrontmost(visualizerMode: .none, scale: .logical1x)
        }
        await #expect(throws: DesktopActionFailure.self) {
            _ = try await capture.captureArea(.zero, visualizerMode: .none, scale: .logical1x)
        }
    }
}

@MainActor
private final class PersistentClassicObservationProbe: DesktopObservationServiceProtocol {
    var engines: [CaptureEnginePreference] = []

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        #expect(request.target == .windowID(77))
        #expect(request.capture.focus == .background)
        self.engines.append(request.capture.engine)
        throw OperationError.captureFailed(reason: "persistent classic observation reached its exact host")
    }
}
