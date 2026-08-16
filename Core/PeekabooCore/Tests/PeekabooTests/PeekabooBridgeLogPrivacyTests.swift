import Foundation
import Testing

struct PeekabooBridgeLogPrivacyTests {
    @Test
    func `Bridge failure logs never publish request derived text`() throws {
        let sourceNames = [
            "PeekabooBridgeServer+Routing.swift",
            "PeekabooBridgeServer+RequestDecoding.swift",
            "PeekabooBridgeServer+Handshake.swift",
            "PeekabooBridgeServer.swift",
            "PeekabooBridgeHost+Clients.swift",
            "PeekabooBridgeHost.swift",
        ]
        let forbiddenPublicInterpolations = [
            "envelope.message, privacy: .public",
            "error.localizedDescription, privacy: .public",
            "failure, privacy: .public",
            "socketPath, privacy: .public",
            "finalPath, privacy: .public",
            "resolvedBundle, privacy: .public",
            "resolvedTeam, privacy: .public",
            "payload.client.bundleIdentifier, privacy: .public",
            "payload.client.teamIdentifier, privacy: .public",
        ]

        for sourceName in sourceNames {
            let source = try String(contentsOf: Self.bridgeSourceURL(sourceName), encoding: .utf8)
            for forbidden in forbiddenPublicInterpolations {
                #expect(!source.contains(forbidden), "\(sourceName) publishes \(forbidden)")
            }
        }

        let routing = try String(
            contentsOf: Self.bridgeSourceURL("PeekabooBridgeServer+Routing.swift"),
            encoding: .utf8)
        #expect(!routing.contains("envelope.message"))
        #expect(!routing.contains("error.localizedDescription"))

        let handshake = try String(
            contentsOf: Self.bridgeSourceURL("PeekabooBridgeServer+Handshake.swift"),
            encoding: .utf8)
        #expect(!handshake.contains("bundleDescription"))
        #expect(!handshake.contains(#"bridge handshake ok pid=\(pid, privacy: .public) bundle="#))
    }

    private static func bridgeSourceURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PeekabooBridge", isDirectory: true)
            .appendingPathComponent(name)
    }
}
