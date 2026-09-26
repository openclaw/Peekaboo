import Foundation

enum BridgeSocketResolver {
    static func explicitBridgeSocket(
        options: CommandRuntimeOptions,
        environment: [String: String]
    ) -> String? {
        if let socket = options.bridgeSocketPath, !socket.isEmpty {
            return socket
        }
        if let socket = environment["PEEKABOO_BRIDGE_SOCKET"], !socket.isEmpty {
            return socket
        }
        return nil
    }

    static func hasNonblankExplicitBridgeSocket(
        options: CommandRuntimeOptions,
        environment: [String: String]
    ) -> Bool {
        guard let socket = self.explicitBridgeSocket(options: options, environment: environment) else { return false }
        return !socket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
