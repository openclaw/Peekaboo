import PeekabooAutomationKit
import Testing
@testable import PeekabooAgentRuntime

struct SeeToolAnnotationTests {
    @Test
    func `annotated screenshot path comes from observation output writer`() {
        let original = "/tmp/test.png"
        let annotated = ObservationOutputWriter.annotatedScreenshotPath(forRawScreenshotPath: original)
        #expect(annotated == "/tmp/test_annotated.png")
    }

    @Test
    func `background annotations stay in returned image without overlay`() {
        #expect(!SeeTool.shouldEmitAnnotationOverlay(captureFocus: .background))
        #expect(SeeTool.shouldEmitAnnotationOverlay(captureFocus: .foreground))
    }
}
