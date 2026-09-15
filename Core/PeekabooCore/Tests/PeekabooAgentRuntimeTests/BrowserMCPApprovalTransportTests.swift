import Foundation
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct BrowserMCPApprovalTransportTests {
    @Test
    func `approval beyond thirty seconds survives the real MCP request timeout`() async throws {
        try await self.withProvider(delay: 45) { client, _, _ in
            let response = try await client.executeTool(name: "peekaboo_browser_connect", arguments: [:])
            let version = try BrowserMCPProviderConnection.version(response, endpoint: Self.endpoint)
            #expect(version.browserVersion == "Chrome/152.0")
            #expect(version.protocolVersion == "1.3")
        }
    }

    @Test
    func `cancellation interrupts an approval already dispatched through MCP`() async throws {
        try await self.withProvider(delay: 300) { client, marker, config in
            let pending = Task { @MainActor in
                try await client.executeTool(name: "peekaboo_browser_connect", arguments: [:])
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let dispatched = FileManager.default.fileExists(atPath: marker.path)
            pending.cancel()
            #expect(dispatched)
            await #expect(throws: CancellationError.self) { try await pending.value }
            #expect(config.autoReconnect == false)
        }
    }

    private static let endpoint = "ws://127.0.0.1:1/devtools/browser/fixture"

    private func withProvider(
        delay: Int,
        operation: (MCPClient, URL, MCPServerConfig) async throws -> Void) async throws
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("approval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("provider.py")
        let marker = directory.appendingPathComponent("dispatched")
        try Self.providerSource.write(to: script, atomically: true, encoding: .utf8)
        var config = BrowserMCPService.chromeDevToolsConfig(webSocketEndpoint: Self.endpoint)
        // Keep the production timeout/reconnect settings; replace only the synthetic provider executable.
        config.command = "/usr/bin/python3"
        config.args = ["-u", script.path, String(delay), marker.path, Self.endpoint]
        let client = MCPClient(name: "approval-fixture", config: config)
        do {
            try await client.connect()
            try await operation(client, marker, config)
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()
        #expect(await !client.isConnected)
    }

    private static let providerSource = #"""
    import json, pathlib, sys, time
    for line in sys.stdin:
        request = json.loads(line)
        if 'id' not in request:
            continue
        method = request.get('method')
        if method == 'initialize':
            result = {'protocolVersion': request['params']['protocolVersion'],
                      'capabilities': {'tools': {}}, 'serverInfo': {'name': 'fixture', 'version': '1'}}
        elif method == 'tools/list':
            result = {'tools': [{'name': 'peekaboo_browser_connect', 'description': 'Synthetic delayed approval',
                                'inputSchema': {'type': 'object', 'properties': {}}}]}
        elif method == 'tools/call':
            pathlib.Path(sys.argv[2]).write_text('dispatched')
            time.sleep(int(sys.argv[1]))
            result = {'content': [{'type': 'text', 'text': json.dumps({
                'webSocketDebuggerUrl': sys.argv[3], 'product': 'Chrome/152.0', 'protocolVersion': '1.3'})}]}
        else:
            result = {}
        print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
    """#
}
