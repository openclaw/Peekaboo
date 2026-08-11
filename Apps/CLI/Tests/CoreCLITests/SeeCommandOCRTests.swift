import Commander
import PeekabooAutomationKit
import Testing
@testable import PeekabooCLI

@Suite(.tags(.fast))
@MainActor
struct SeeCommandOCRTests {
    @Test
    func `OCR flag binds and maps to a bounded additive detection request`() throws {
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: SeeCommand.self,
            parsedValues: ParsedValues(
                positional: [],
                options: [
                    "app": ["Calendar"],
                    "windowId": ["119"],
                    "timeout": ["7s"],
                ],
                flags: ["ocr"]
            )
        )

        #expect(command.ocr)
        try command.validateMergedOptions()
        let request = try command.makeObservationRequest(
            target: .app(identifier: "Calendar", window: .id(119))
        )

        #expect(request.detection.mode == .accessibilityAndOCR)
        #expect(!request.detection.preferOCR)
        #expect(!request.detection.allowWebFocusFallback)
        #expect(request.timeout.overall == 7)
        #expect(request.timeout.detection == 7)
        #expect(request.timeout.ocr == 7)
        #expect(request.capture.focus == .background)
    }

    @Test
    func `OCR stays opt in and is discoverable in See help`() throws {
        let command = try SeeCommand.parse(["--app", "Calendar"])
        let request = try command.makeObservationRequest(
            target: .app(identifier: "Calendar", window: .automatic)
        )
        let ocrFlag = try #require(SeeCommand.commanderSignature().flags.first { $0.label == "ocr" })

        #expect(!command.ocr)
        #expect(request.detection.mode == .accessibility)
        #expect(!request.detection.preferOCR)
        #expect(request.timeout.ocr == nil)
        #expect(ocrFlag.names.contains(.long("ocr")))
        #expect(ocrFlag.help?.contains("local Vision OCR") == true)
    }

    @Test(arguments: [
        ["--ocr", "--no-elements"],
        ["--ocr", "--tree", "--no-screenshot"],
        ["--ocr", "--path", "-"],
        ["--ocr", "--mode", "area", "--region", "0,0,100,100"],
        ["--ocr", "--mode", "multi"],
    ])
    func `OCR refuses incompatible capture shapes before dispatch`(arguments: [String]) throws {
        let command = try SeeCommand.parse(arguments)

        #expect(throws: ValidationError.self) {
            try command.validateMergedOptions()
        }
    }
}
