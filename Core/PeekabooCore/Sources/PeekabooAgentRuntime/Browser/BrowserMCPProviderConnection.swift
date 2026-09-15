import Foundation
import MCP
import TachikomaMCP

struct BrowserMCPDevToolsVersion: Sendable, Equatable {
    let browserVersion: String
    let protocolVersion: String
}

extension BrowserMCPManaging {
    func verifyBrowserConnection(serverName: String, endpoint: String) async throws -> BrowserMCPDevToolsVersion {
        let response = try await self.executeTool(
            serverName: serverName,
            toolName: "peekaboo_browser_connect",
            arguments: [:])
        return try BrowserMCPProviderConnection.version(response, endpoint: endpoint)
    }
}

enum BrowserMCPProviderConnection {
    static func version(_ response: ToolResponse, endpoint: String) throws -> BrowserMCPDevToolsVersion {
        if response.isError {
            let text = response.content.compactMap { item -> String? in
                guard case let .text(value, _, _) = item else { return nil }
                return String(value.prefix(512))
            }.joined(separator: " ")
            let reason = if text.contains("403") {
                "Chrome refused the WebSocket upgrade (HTTP 403)."
            } else if text.contains("404") {
                "Chrome could not find the published WebSocket (HTTP 404)."
            } else if text.contains("ECONNREFUSED") {
                "Chrome's published TCP listener refused the connection."
            } else {
                "Chrome's persistent provider could not complete Browser.getVersion."
            }
            throw BrowserMCPConnectionError.connectionProbeFailed(
                reason +
                    " Check chrome://inspect/#remote-debugging and the pending approval in the intended profile. " +
                    "Check browser status before explicitly reconnecting; Peekaboo did not retry the attachment.")
        }
        guard response.content.count == 1,
              case let .text(text, _, _) = response.content[0],
              text.utf8.count <= 64 * 1024,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              object["webSocketDebuggerUrl"] as? String == endpoint,
              let product = object["product"] as? String,
              !product.isEmpty,
              let protocolVersion = object["protocolVersion"] as? String, !protocolVersion.isEmpty
        else {
            throw BrowserMCPConnectionError.connectionProbeFailed(
                "The persistent provider could not verify Browser.getVersion on the exact Chrome WebSocket. " +
                    "Check chrome://inspect/#remote-debugging in the intended profile and allow the pending " +
                    "remote-debugging request. A pipe-only Chrome does not expose a TCP listener. " +
                    "Check browser status before explicitly reconnecting.")
        }
        return BrowserMCPDevToolsVersion(browserVersion: product, protocolVersion: protocolVersion)
    }
}
