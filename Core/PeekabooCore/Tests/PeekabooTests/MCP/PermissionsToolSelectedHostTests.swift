import Foundation
import MCP
import PeekabooAutomationKit
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooBridge
@testable import PeekabooCore

@Suite(.serialized)
struct PermissionsToolSelectedHostTests {
    @Test
    func `permission provider remains additive at protocol 1_22`() {
        #expect(PeekabooBridgeConstants.protocolVersion == .init(major: 1, minor: 31))
    }

    private struct PermissionCase: Sendable, CustomTestStringConvertible {
        let screenRecording: Bool
        let accessibility: Bool
        let postEvent: Bool

        var testDescription: String {
            "screen=\(self.screenRecording)-accessibility=\(self.accessibility)-postEvent=\(self.postEvent)"
        }

        var status: PermissionsStatus {
            PermissionsStatus(
                screenRecording: self.screenRecording,
                accessibility: self.accessibility,
                postEvent: self.postEvent)
        }
    }

    private static let permissionCases: [PermissionCase] = [false, true].flatMap { screenRecording in
        [false, true].flatMap { accessibility in
            [false, true].map { postEvent in
                PermissionCase(
                    screenRecording: screenRecording,
                    accessibility: accessibility,
                    postEvent: postEvent)
            }
        }
    }

    @Test(arguments: permissionCases)
    @MainActor
    private func `one selected-host snapshot projects every permission combination`(
        permissionCase: PermissionCase) async throws
    {
        let provider = RecordingPermissionsStatusProvider(status: permissionCase.status)
        let context = await MCPToolTestHelpers.makeContext(permissionsStatusProvider: provider)
        let response = try await PermissionsTool(context: context).execute(arguments: ToolArguments(raw: [:]))

        #expect(provider.callCount == 1)
        #expect(response.isError == !(permissionCase.screenRecording && permissionCase.accessibility))

        let text = try #require(Self.text(from: response))
        #expect(text.contains("Screen Recording (Required)"))
        #expect(text.contains("Accessibility (Required)"))
        #expect(text.contains("Event Synthesizing (Action-specific)"))
        #expect(text.contains("Event Synthesizing is not globally required") == !permissionCase.postEvent)

        let meta = try #require(Self.meta(from: response))
        #expect(meta["permission_snapshot_available"] == .bool(true))
        #expect(meta["screen_recording"] == .bool(permissionCase.screenRecording))
        #expect(meta["accessibility"] == .bool(permissionCase.accessibility))
        #expect(meta["event_synthesizing"] == .bool(permissionCase.postEvent))
        #expect(meta["required_permissions_granted"] ==
            .bool(permissionCase.screenRecording && permissionCase.accessibility))
        let expectedLimits: Value = permissionCase.postEvent
            ? .array([])
            : .array([
                .string("background keyboard input"),
                .string("foreground synthetic pointer input"),
            ])
        #expect(meta["event_synthesizing_limits"] == expectedLimits)
    }

    @Test
    @MainActor
    func `provider failure preserves the structured permission shape`() async throws {
        let provider = RecordingPermissionsStatusProvider(error: PermissionProviderError.unavailable)
        let context = await MCPToolTestHelpers.makeContext(permissionsStatusProvider: provider)
        let response = try await PermissionsTool(context: context).execute(arguments: ToolArguments(raw: [:]))

        #expect(response.isError)
        #expect(provider.callCount == 1)
        let meta = try #require(Self.meta(from: response))
        #expect(meta["permission_snapshot_available"] == .bool(false))
        #expect(meta["screen_recording"] == .null)
        #expect(meta["accessibility"] == .null)
        #expect(meta["event_synthesizing"] == .null)
        #expect(meta["required_permissions_granted"] == .null)
        #expect(meta["event_synthesizing_limits"] == .array([]))
    }

    @Test
    @MainActor
    func `remote selected host wins and performs one complete Bridge permission read`() async throws {
        let socketPath = "/tmp/peekaboo-selected-permissions-\(UUID().uuidString).sock"
        let expected = PermissionsStatus(
            screenRecording: false,
            accessibility: true,
            postEvent: true)
        let evaluations = PermissionEvaluationRecorder(status: expected)
        let server = PeekabooBridgeServer(
            services: StubServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.permissionsStatus],
            permissionStatusEvaluator: { _ in evaluations.evaluate() })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 1)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 1)
        _ = try await client.handshake(client: PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peekaboo.permissions-tests",
            teamIdentifier: nil,
            processIdentifier: getpid()))
        let handshakeEvaluationCount = evaluations.callCount
        let remote = RemotePeekabooServices(client: client)
        let context = MCPToolContext(services: remote)
        let response = try await PermissionsTool(context: context).execute(arguments: ToolArguments(raw: [:]))

        #expect(evaluations.callCount == handshakeEvaluationCount + 1)
        #expect(response.isError)
        let meta = try #require(Self.meta(from: response))
        #expect(meta["screen_recording"] == .bool(false))
        #expect(meta["accessibility"] == .bool(true))
        #expect(meta["event_synthesizing"] == .bool(true))
    }

    private static func text(from response: ToolResponse) -> String? {
        guard case let .text(text, _, _) = response.content.first else { return nil }
        return text
    }

    private static func meta(from response: ToolResponse) -> [String: Value]? {
        guard case let .object(meta)? = response.meta else { return nil }
        return meta
    }
}

@MainActor
private final class RecordingPermissionsStatusProvider: PermissionsStatusProviding {
    private let result: Result<PermissionsStatus, any Error>
    private(set) var callCount = 0

    init(status: PermissionsStatus) {
        self.result = .success(status)
    }

    init(error: any Error) {
        self.result = .failure(error)
    }

    func permissionsStatus() async throws -> PermissionsStatus {
        self.callCount += 1
        return try self.result.get()
    }
}

@MainActor
private final class PermissionEvaluationRecorder {
    private let status: PermissionsStatus
    private(set) var callCount = 0

    init(status: PermissionsStatus) {
        self.status = status
    }

    func evaluate() -> PermissionsStatus {
        self.callCount += 1
        return self.status
    }
}

private enum PermissionProviderError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "selected host unavailable"
    }
}
