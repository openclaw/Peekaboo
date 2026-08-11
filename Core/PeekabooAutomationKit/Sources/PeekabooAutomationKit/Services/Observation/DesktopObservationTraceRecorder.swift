import Foundation

@MainActor
final class DesktopObservationTraceRecorder {
    private var spans: [ObservationSpan] = []

    func span<T>(_ name: String, operation: () async throws -> T) async throws -> T {
        let start = ContinuousClock.now
        do {
            let value = try await operation()
            self.record(name, start: start)
            return value
        } catch {
            self.record(name, start: start, metadata: ["success": "false"])
            throw error
        }
    }

    func timings() -> ObservationTimings {
        ObservationTimings(spans: self.spans)
    }

    func append(_ spans: [ObservationSpan]) {
        self.spans.append(contentsOf: spans)
    }

    func annotateLastSpan(named name: String, metadata: [String: String]) {
        guard !metadata.isEmpty,
              let index = self.spans.lastIndex(where: { $0.name == name })
        else {
            return
        }
        let span = self.spans[index]
        self.spans[index] = ObservationSpan(
            name: span.name,
            durationMS: span.durationMS,
            metadata: span.metadata.merging(metadata) { _, new in new })
    }

    func record(_ name: String, start: ContinuousClock.Instant, metadata: [String: String] = [:]) {
        let duration = start.duration(to: ContinuousClock.now)
        let milliseconds = Double(duration.components.seconds * 1000)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
        self.spans.append(ObservationSpan(name: name, durationMS: milliseconds, metadata: metadata))
    }
}
