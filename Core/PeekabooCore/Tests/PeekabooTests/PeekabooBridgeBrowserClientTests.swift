import PeekabooBridgeTestSupport
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeBrowserClientTests {
    @Test(arguments: ["status", "connect", "execute"])
    func `browser client preserves structured Bridge errors`(operation: String) async throws {
        let expected = PeekabooBridgeErrorEnvelope(
            code: .operationNotSupported,
            message: "browser backend unavailable",
            details: "npx is not available to this host")
        let peer = try ScriptedBridgePeer(steps: [.respond(.error(expected))])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)

        do {
            switch operation {
            case "status":
                _ = try await client.browserStatus(channel: "stable")
            case "connect":
                _ = try await client.browserConnect(
                    channel: "stable",
                    browserURL: "http://127.0.0.1:9222")
            case "execute":
                _ = try await client.browserExecute(.init(
                    toolName: "list_pages",
                    arguments: [:],
                    channel: "stable"))
            default:
                Issue.record("Unknown test operation")
            }
            Issue.record("Expected the structured browser error")
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            #expect(envelope.code == expected.code)
            #expect(envelope.message == expected.message)
            #expect(envelope.details == expected.details)
        }
        await peer.waitUntilFinished()
    }
}
