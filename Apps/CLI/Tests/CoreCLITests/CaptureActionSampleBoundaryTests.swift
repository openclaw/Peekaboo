import Foundation
import Testing
@testable import PeekabooCLI

struct CaptureActionSampleBoundaryTests {
    @Test
    func `sample offsets round trip exactly above JSON integer precision`() throws {
        let sample = CaptureActionManifest.SampleBoundary(
            actionCompletedOffsetNs: 9_007_199_254_740_993,
            lastSampleStartedOffsetNs: 9_007_199_254_740_994
        )
        let data = try JSONEncoder().encode(sample)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object["actionCompletedOffsetNs"] == "9007199254740993")
        let decoded = try JSONDecoder().decode(CaptureActionManifest.SampleBoundary.self, from: data)
        #expect(decoded.actionCompletedOffsetNs == sample.actionCompletedOffsetNs)
        #expect(decoded.lastSampleStartedOffsetNs == sample.lastSampleStartedOffsetNs)
        #expect(decoded.samplesAfterAction)
    }

    @Test(arguments: ["", "-1", "+1", "01", "1.0", "18446744073709551616"])
    func `sample offsets reject noncanonical and overflowing decimal strings`(_ offset: String) throws {
        for key in ["actionCompletedOffsetNs", "lastSampleStartedOffsetNs"] {
            var object = ["actionCompletedOffsetNs": "100", "lastSampleStartedOffsetNs": "101"]
            object[key] = offset
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(CaptureActionManifest.SampleBoundary.self, from: data)
            }
        }
    }
}
