import MCP
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct BrowserMCPSessionManagerChannelRefusalTests {
    @Test
    func `channel authority refusal is safe before permission dispatch`() async {
        let manager = RefusingChannelBrowserMCPManager()
        let resolve: BrowserMCPChannelEndpointResolver.Resolve = { target in
            throw BrowserMCPConnectionError.channelEndpointUnavailable(target.channel, "unsafe authority")
        }
        let revalidate: BrowserMCPChannelEndpointResolver.Revalidate = { _, _ in }
        let session = Self.session(
            manager: manager,
            resolver: BrowserMCPChannelEndpointResolver(resolve, revalidate: revalidate))

        do {
            _ = try await session.connect(channel: .stable)
            Issue.record("Expected channel authority refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        } catch {
            Issue.record("Expected canonical refusal, got \(error)")
        }
        #expect(manager.addServerCount == 0)
        #expect(manager.executeCount == 0)
        #expect(manager.removeServerCount == 0)
    }

    @Test
    func `permission bearing WebSocket failures are indeterminate before MCP spawn`() async {
        let errors: [BrowserMCPConnectionError] = [
            .permissionBearingConnectionFailed("HTTP 403"),
            .permissionBearingConnectionFailed("approval timed out"),
            .permissionBearingConnectionFailed("malformed CDP"),
            .permissionBearingConnectionCancelled,
        ]

        for error in errors {
            let manager = RefusingChannelBrowserMCPManager()
            let resolver = BrowserMCPChannelEndpointResolver(
                resolveInitial: { _, attempt in
                    attempt.state.markPermissionDispatchStarted()
                    throw error
                },
                revalidate: { _, _ in })
            let session = Self.session(manager: manager, resolver: resolver)

            do {
                _ = try await session.connect(channel: .stable)
                Issue.record("Expected permission-bearing failure")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .indeterminate)
                #expect(failure.outcome.delivery == .init(mechanism: .browserProtocol, mode: .foreground))
                #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
                #expect(failure.outcome.retrySafety == .unsafe)
            } catch {
                Issue.record("Expected canonical indeterminate failure, got \(error)")
            }
            #expect(manager.addServerCount == 0)
            #expect(manager.executeCount == 0)
            #expect(manager.removeServerCount == 0)
        }
    }

    private static func session(
        manager: RefusingChannelBrowserMCPManager,
        resolver: BrowserMCPChannelEndpointResolver) -> BrowserMCPSessionManager
    {
        let browser = DetectedBrowser(
            name: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            processIdentifier: 50,
            processStartIdentity: 2050,
            version: "151.0",
            channel: .stable)
        return BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [browser] },
            processStartIdentity: { _ in 2050 },
            processBundleIdentifier: { _ in "com.google.Chrome" },
            processCodeSignatureValidator: { _, _, _ in true },
            endpointResolver: BrowserMCPDevToolsEndpointResolver { _ in
                throw BrowserMCPConnectionError.invalidEndpoint("unexpected HTTP resolution")
            },
            channelEndpointResolver: resolver,
            environment: [:])
    }
}

@MainActor
private final class RefusingChannelBrowserMCPManager: BrowserMCPManaging {
    var addServerCount = 0
    var executeCount = 0
    var removeServerCount = 0

    func hasServer(name _: String) -> Bool {
        false
    }

    func isServerConnected(name _: String) async -> Bool {
        false
    }

    func serverToolCount(name _: String) async -> Int {
        0
    }

    func addServer(name _: String, config _: MCPServerConfig) async throws {
        self.addServerCount += 1
    }

    func removeServer(name _: String) async {
        self.removeServerCount += 1
    }

    func executeTool(
        serverName _: String,
        toolName _: String,
        arguments _: [String: Any]) async throws -> ToolResponse
    {
        self.executeCount += 1
        return ToolResponse.text("unexpected")
    }
}
