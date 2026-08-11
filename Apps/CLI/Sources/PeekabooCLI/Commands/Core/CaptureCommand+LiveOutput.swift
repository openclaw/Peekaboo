import Foundation
import PeekabooCore

@MainActor
extension CaptureLiveCommand {
    func output(_ result: LiveCaptureSessionResult) {
        let meta = CaptureMetaSummary.make(from: result)
        if self.jsonOutput {
            outputSuccessCodable(data: result, logger: self.outputLogger)
            return
        }
        print("""
        🎥 capture sampled \(result.stats.framesSampled) frames at \
        \(String(format: "%.2f", result.stats.sampledFps)) FPS, kept \(result.stats.framesKept) at \
        \(String(format: "%.2f", result.stats.keptFps)) FPS,
        contact sheet: \(meta.contactPath), diff: \(meta.diffAlgorithm) @ \(meta.diffScale),
        grid \(meta.contactColumns)x\(meta
            .contactRows) thumb \(Int(meta.contactThumbSize.width))x\(Int(meta.contactThumbSize.height))
        """)
        for frame in result.frames {
            print(
                "🖼️  \(frame.reason.rawValue) t=\(frame.timestampMs)ms "
                    + "Δ=\(Self.formatChangePercent(frame.changePercent))% → \(frame.path)"
            )
        }
        for warning in result.warnings {
            print("⚠️  \(warning.code.rawValue): \(warning.message)")
        }
    }

    static func formatChangePercent(_ value: Double) -> String {
        if value > 0, value < 0.01 {
            return String(format: "%.3g", value)
        }
        return String(format: "%.2f", value)
    }
}
