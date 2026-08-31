import Foundation
import PeekabooBridge

/// Daemon health observes browser diagnostics without joining browser lifecycle or native discovery work.
@MainActor
final class DaemonBrowserDiagnostics {
    private var lastStatus: PeekabooBridgeBrowserStatus?
    private var lastFailure: String?
    private var refresh: Task<Void, Never>?
    private var stopped = false

    func snapshot(
        read: @escaping @MainActor @Sendable () async throws -> PeekabooBridgeBrowserStatus)
        -> PeekabooBridgeBrowserStatus
    {
        if !self.stopped, self.refresh == nil {
            self.refresh = Task { @MainActor [weak self] in
                do {
                    let result = try await read()
                    guard !Task.isCancelled else { return }
                    self?.lastStatus = result
                    self?.lastFailure = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.lastFailure = error.localizedDescription
                }
                self?.refresh = nil
            }
        }
        return PeekabooBridgeBrowserStatus(
            isConnected: self.lastStatus?.isConnected ?? false,
            toolCount: self.lastStatus?.toolCount ?? 0,
            detectedBrowsers: self.lastStatus?.detectedBrowsers ?? [],
            connectionReceipt: self.lastStatus?.connectionReceipt,
            error: self.lastFailure ?? self.lastStatus.map {
                "Cached browser diagnostics; use browser status for a fresh observation." +
                    ($0.error.map { " Last observation: \($0)" } ?? "")
            } ?? "Browser diagnostics have not completed; discovery or connection state is unavailable.",
            providerSessionEpoch: self.lastStatus?.providerSessionEpoch,
            observation: .indeterminate)
    }

    func stop() {
        self.stopped = true
        self.refresh?.cancel()
    }

    deinit {
        self.refresh?.cancel()
    }
}
