import Foundation
import Testing
@testable import PeekabooFoundation

struct ErrorDurationRenderingTests {
    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity, Double(Int.max), Double.greatestFiniteMagnitude])
    func `retry descriptions remain renderable`(duration: Double) {
        let description = PeekabooError.rateLimited(retryAfter: duration, message: "owned retry").localizedDescription
        #expect(description.contains("owned retry"))
        #expect(description.contains("retry after"))
    }

    @Test
    func `ordinary retry descriptions keep their whole second format`() {
        #expect(PeekabooError.rateLimited(retryAfter: 3.25, message: "retry").localizedDescription ==
            "Rate limited (retry after 3s): retry")
        #expect(PeekabooError.rateLimited(retryAfter: nil, message: "retry").localizedDescription ==
            "Rate limited: retry")
    }

    @Test(arguments: [Double(Int.max), Double.greatestFiniteMagnitude])
    func `detection boundary descriptions remain renderable`(duration: Double) {
        let description = CaptureError.detectionTimedOut(duration).localizedDescription
        #expect(description.contains("Element detection timed out"))
        #expect(description.contains("peekaboo see --timeout"))
    }

    @Test
    func `ordinary detection descriptions keep their units`() {
        #expect(CaptureError.detectionTimedOut(2).localizedDescription.contains("after 2s."))
        #expect(CaptureError.detectionTimedOut(0.025).localizedDescription.contains("after 25ms."))
    }
}
