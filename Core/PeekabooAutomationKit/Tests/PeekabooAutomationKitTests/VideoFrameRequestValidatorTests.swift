import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct VideoFrameRequestValidatorTests {
    struct Case: Sendable {
        let sampleFps: Double?
        let everyMs: Int?
        let startMs: Int?
        let endMs: Int?
        let resolutionCap: Double?
        let expectedMessage: String
    }

    @Test(arguments: [
        Case(
            sampleFps: 0,
            everyMs: nil,
            startMs: nil,
            endMs: nil,
            resolutionCap: nil,
            expectedMessage: "Invalid input: sample-fps must be a positive finite value"),
        Case(
            sampleFps: nil,
            everyMs: 0,
            startMs: nil,
            endMs: nil,
            resolutionCap: nil,
            expectedMessage: "Invalid input: every-ms must be greater than zero"),
        Case(
            sampleFps: nil,
            everyMs: nil,
            startMs: -1,
            endMs: nil,
            resolutionCap: nil,
            expectedMessage: "Invalid input: start-ms must be zero or greater"),
        Case(
            sampleFps: nil,
            everyMs: nil,
            startMs: nil,
            endMs: -1,
            resolutionCap: nil,
            expectedMessage: "Invalid input: end-ms must be zero or greater"),
        Case(
            sampleFps: nil,
            everyMs: nil,
            startMs: nil,
            endMs: 0,
            resolutionCap: nil,
            expectedMessage: "Invalid input: end-ms must exceed start-ms"),
        Case(
            sampleFps: nil,
            everyMs: nil,
            startMs: 2000,
            endMs: 1000,
            resolutionCap: nil,
            expectedMessage: "Invalid input: end-ms must exceed start-ms"),
        Case(
            sampleFps: nil,
            everyMs: nil,
            startMs: nil,
            endMs: nil,
            resolutionCap: 0,
            expectedMessage: "Invalid input: resolution-cap must be a positive finite value"),
    ])
    func `invalid video request values fail synchronously`(_ testCase: Case) {
        let error = #expect(throws: PeekabooError.self) {
            try VideoFrameRequestValidator.validate(
                sampleFps: testCase.sampleFps,
                everyMs: testCase.everyMs,
                startMs: testCase.startMs,
                endMs: testCase.endMs,
                resolutionCap: testCase.resolutionCap)
        }
        #expect(error?.localizedDescription == testCase.expectedMessage)
    }

    @Test
    func `valid video request values pass synchronously`() {
        #expect(throws: Never.self) {
            try VideoFrameRequestValidator.validate(
                sampleFps: 2,
                everyMs: nil,
                startMs: 0,
                endMs: 2000,
                resolutionCap: 1440)
        }
    }
}
