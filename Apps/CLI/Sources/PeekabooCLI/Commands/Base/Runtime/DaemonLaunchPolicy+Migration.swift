import Foundation

extension DaemonLaunchPolicy {
    @MainActor
    static func performMigrationLaunch<T: Sendable>(
        launch: @escaping @MainActor @Sendable () async throws -> T,
        rollback: @escaping @MainActor @Sendable (T) async -> Void
    ) async throws -> T {
        let result = try await launch()
        // A replacement launcher can finish after ignoring cancellation. Roll that exact result
        // back before the migration crosses its next mutation boundary and stops the legacy daemon.
        if Task.isCancelled {
            await rollback(result)
            throw CancellationError()
        }
        return result
    }
}
