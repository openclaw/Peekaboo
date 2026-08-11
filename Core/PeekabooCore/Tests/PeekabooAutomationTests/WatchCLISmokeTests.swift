import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomation

struct WatchCLISmokeTests {
    @Test
    func `Contact sheet sampling metadata is present`() {
        let sheet = CaptureContactSheet(
            path: "/tmp/contact.png",
            file: "contact.png",
            columns: 6,
            rows: 2,
            thumbSize: CGSize(width: 200, height: 200),
            sampledFrameIndexes: [0, 2, 4])
        #expect(sheet.sampledFrameIndexes.count == 3)
        #expect(sheet.columns == 6)
    }

    @Test
    func `Diff metadata is carried through result`() {
        let result = CaptureSessionResult(
            source: .live,
            videoIn: nil,
            videoOut: nil,
            frames: [],
            contactSheet: CaptureContactSheet(
                path: "/tmp/contact.png",
                file: "contact.png",
                columns: 1,
                rows: 1,
                thumbSize: CGSize(width: 100, height: 100),
                sampledFrameIndexes: []),
            metadataFile: "/tmp/metadata.json",
            stats: CaptureStats(
                durationMs: 1000,
                fpsIdle: 2,
                fpsActive: 8,
                fpsEffective: 1,
                framesKept: 0,
                framesDropped: 0,
                maxFramesHit: false,
                maxMbHit: false),
            scope: CaptureScope(kind: .screen),
            diffAlgorithm: "fast",
            diffScale: "w256",
            options: CaptureOptionsSnapshot(
                duration: 60,
                idleFps: 2,
                activeFps: 8,
                changeThresholdPercent: 2.5,
                heartbeatSeconds: 5,
                quietMsToIdle: 1000,
                maxFrames: 800,
                maxMegabytes: Int?.none,
                highlightChanges: false,
                captureFocus: CaptureFocus.auto,
                resolutionCap: 1440,
                diffStrategy: CaptureOptions.DiffStrategy.fast,
                diffBudgetMs: 30),
            warnings: [])
        #expect(result.diffAlgorithm == "fast")
        #expect(result.diffScale == "w256")
        #expect(result.options.diffBudgetMs == 30)
    }

    @Test
    func `Legacy capture stats decode with zero video failures`() throws {
        let data = Data("""
        {
          "durationMs": 1000, "fpsIdle": 2, "fpsActive": 8, "fpsEffective": 1,
          "framesKept": 1, "framesDropped": 2, "maxFramesHit": false, "maxMbHit": false
        }
        """.utf8)

        let stats = try JSONDecoder().decode(CaptureStats.self, from: data)

        #expect(stats.decodeFailures == 0)
        #expect(stats.totalDurationMs == 1000)
        #expect(stats.samplingDurationMs == 1000)
        #expect(stats.keptFps == 1)
        #expect(stats.framesDiffFiltered == 2)
        #expect(stats.framesDropped == 2)
    }
}
