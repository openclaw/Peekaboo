import Foundation
import PeekabooCore

@MainActor
extension CaptureLiveCommand {
    func buildOptions() throws -> CaptureOptions {
        let duration = max(1, min(self.duration?.seconds ?? 60, 180))
        let cadence = try CaptureCadence.validated(idleFps: self.idleFps, activeFps: self.activeFps)
        let threshold = min(max(self.threshold ?? 2.5, 0), 100)
        let heartbeat = max(self.heartbeat?.seconds ?? 5, 0)
        let quiet = max(self.quiet?.roundedMilliseconds ?? 1000, 0)
        let maxFrames = max(self.maxFrames ?? 800, 1)
        let resolutionCap = self.resolutionCap ?? 1440
        let diffStrategy = try CaptureCommandOptionParser.diffStrategy(self.diffStrategy)
        let diffBudgetMs = self.diffBudget?.roundedMilliseconds ?? (diffStrategy == .quality ? 30 : nil)
        let maxMb = self.maxMb.flatMap { $0 > 0 ? $0 : nil }

        return CaptureOptions(
            duration: duration,
            idleFps: cadence.idleFps,
            activeFps: cadence.activeFps,
            changeThresholdPercent: threshold,
            heartbeatSeconds: heartbeat,
            quietMsToIdle: quiet,
            maxFrames: maxFrames,
            maxMegabytes: maxMb,
            highlightChanges: self.highlightChanges,
            captureFocus: self.captureFocus,
            resolutionCap: resolutionCap,
            diffStrategy: diffStrategy,
            diffBudgetMs: diffBudgetMs
        )
    }

    func resolveOutputDirectory() throws -> URL {
        CaptureCommandPathResolver.outputDirectory(from: self.path)
    }
}
