import Dispatch

/// AppKit application getters can wait on LaunchServices, even when they only read metadata.
enum BrowserMCPApplicationMetadata {
    private static let queue = DispatchQueue(label: "boo.peekaboo.browser-application-metadata", qos: .utility)

    static func read<Value: Sendable>(_ read: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            self.queue.async {
                continuation.resume(returning: read())
            }
        }
    }
}
