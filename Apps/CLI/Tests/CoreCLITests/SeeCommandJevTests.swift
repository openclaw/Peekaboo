import Commander
import CoreGraphics
import Foundation
import ImageIO
import PeekabooFoundation
import Testing
import UniformTypeIdentifiers
@testable import PeekabooCLI
@testable import PeekabooCore

@Suite(.serialized, .tags(.safe))
struct SeeCommandJevTests {
    // MARK: Options

    @Test
    func `jev options parse from the command line`() throws {
        let pick = try SeeCommand.parse(["--app", "Rill", "--jev-pick", "the Send button"])
        #expect(pick.jevPick == "the Send button")
        #expect(pick.requestsJev)

        let check = try SeeCommand.parse(["--app", "Rill", "--jev-check", "The sidebar is collapsed."])
        #expect(check.jevCheck == "The sidebar is collapsed.")

        let locate = try SeeCommand.parse(["--app", "Rill", "--jev-locate", "the close button"])
        #expect(locate.jevLocate == "the close button")

        let plain = try SeeCommand.parse(["--app", "Rill"])
        #expect(!plain.requestsJev)
    }

    @Test
    func `only one jev question per observation`() throws {
        let command = try SeeCommand.parse([
            "--app", "Rill", "--jev-pick", "the Send button", "--jev-check", "Send is enabled.",
        ])
        #expect(throws: ValidationError.self) { try command.validateMergedOptions() }
    }

    @Test
    func `jev locate needs the screenshot and jev pick needs the elements`() throws {
        let locate = try SeeCommand.parse([
            "--app", "Rill", "--tree", "--no-screenshot", "--jev-locate", "the close button",
        ])
        #expect(throws: ValidationError.self) { try locate.validateMergedOptions() }

        let pick = try SeeCommand.parse(["--app", "Rill", "--no-elements", "--jev-pick", "the Send button"])
        #expect(throws: ValidationError.self) { try pick.validateMergedOptions() }

        let treeOnlyCheck = try SeeCommand.parse([
            "--app", "Rill", "--tree", "--no-screenshot", "--jev-check", "Send is enabled.",
        ])
        try treeOnlyCheck.validateMergedOptions()
    }

    // MARK: Candidates

    @Test
    @MainActor
    func `candidates keep disabled controls and labelled rows`() {
        let elements = [
            Self.element("B1", .button, label: "Send", enabled: false),
            Self.element("G1", .group, label: "Thread Engine integration"),
            Self.element("G2", .group, label: nil),
            Self.element("T1", .staticText, label: "Message"),
            Self.element("F1", .textField, label: "Message composer", value: "draft"),
        ]
        let candidates = SeeCommand.jevCandidates(elements)

        #expect(candidates.map(\.element.id) == ["B1", "G1", "F1"])
        #expect(candidates[0].description == "button \"Send\" disabled")
        #expect(candidates[1].description == "group \"Thread Engine integration\"")
        #expect(candidates[2].description == "textField \"Message composer\" value=\"draft\"")
    }

    @Test
    @MainActor
    func `candidates stop at the Jev option limit`() {
        let elements = (0..<300).map { Self.element("B\($0)", .button, label: "Button \($0)") }
        #expect(SeeCommand.jevCandidates(elements).count == 255)
    }

    @Test
    func `confidence accepts sure picks and clear leads only`() {
        #expect(SeeCommand.jevConfident(probability: 0.6, runnerUp: 0.4))
        #expect(SeeCommand.jevConfident(probability: 0.55, runnerUp: 0.2))
        #expect(!SeeCommand.jevConfident(probability: 0.55, runnerUp: 0.3))
        #expect(!SeeCommand.jevConfident(probability: 0.44, runnerUp: 0.1))
    }

    // MARK: Requests and answers

    @Test
    func `requests attach images under a unique reference with the opt-in`() throws {
        let plain = JevRequest.make(
            model: "jev-latest", state: ["request": "x"], questions: ["q": .noul("Is it?")], image: nil
        )
        #expect(plain.assets == nil)
        #expect(!plain.needsImageOptIn)

        let image = JevRequest.make(
            model: "jev-latest", state: ["request": "x"], questions: ["q": .noul("Is it?")], image: Data([1, 2, 3])
        )
        let reference = try #require(image.state["picture"])
        #expect(reference.hasPrefix("peekaboo-image-"))
        #expect(image.assets?[reference]?.data_base64 == "AQID")
        #expect(image.needsImageOptIn)

        let box = JevRequest.make(model: "jev-preview", state: [:], questions: ["w": .box("Where?")], image: nil)
        #expect(box.needsImageOptIn)
    }

    @Test
    func `request encodes Jev's wire shape`() throws {
        let request = JevRequest.make(
            model: "jev-latest",
            state: ["request": "the Send button"],
            questions: ["target": .choice("Which one?", criteria: ["B1": "button \"Send\""])],
            image: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = try #require(try String(data: encoder.encode(request), encoding: .utf8))
        #expect(json == #"{"model":"jev-latest","questions":{"target":{"criteria":{"B1":"button \"Send\""},"#
            + #""instructions":"Which one?","type":"choice"}},"state":{"request":"the Send button"}}"#)
    }

    @Test
    func `answers decode choices, bare and keyed yes-no, and boxes`() throws {
        let reply = Data("""
        {"answers": {
          "target": {"choice": "B1", "probabilities": {"B1": 0.9, "G1": 0.08, "F1": 0.02}},
          "bare": 0.83,
          "keyed": {"noul": 0.12},
          "where": {"box": {"left": 0.1, "top": 0.2, "right": 0.3, "bottom": 0.6}, "confidence": 0.84}
        }, "usage": {"input_tokens": 3511, "output_tokens": 278}}
        """.utf8)
        let response = try JSONDecoder().decode(JevResponse.self, from: reply)

        let odds = try #require(response.answers["target"]?.choiceProbabilities)
        #expect(odds.probability == 0.9)
        #expect(odds.runnerUp == 0.08)
        #expect(response.answers["bare"]?.noul == 0.83)
        #expect(response.answers["keyed"]?.noul == 0.12)
        #expect(response.answers["where"]?.box == JevBox(left: 0.1, top: 0.2, right: 0.3, bottom: 0.6))
        #expect(response.usage == JevUsage(input_tokens: 3511, output_tokens: 278))
    }

    // MARK: Images

    @Test
    func `images within bounds are sent unchanged`() throws {
        let png = try Self.png(width: 1220, height: 790)
        let fitted = try SeeCommand.fitForJev(png)
        #expect(fitted.png == png)
        #expect(fitted.scale == 1)
        #expect(fitted.sentWidth == 1220)
    }

    @Test
    func `large images shrink and small ones pad`() throws {
        let large = try SeeCommand.fitForJev(Self.png(width: 3136, height: 1000))
        #expect(large.sentWidth == JevClient.maxSide)
        #expect(large.scale == 2)

        let small = try SeeCommand.fitForJev(Self.png(width: 400, height: 100))
        #expect(small.sentWidth == 400)
        #expect(small.sentHeight == JevClient.minSide)
        #expect(small.scale == 1)
    }

    @Test
    func `boxes map back to capture pixels through scale and padding`() {
        let image = SeeCommand.JevImage(png: Data(), scale: 2, sentWidth: 1568, sentHeight: 500)
        let rect = SeeCommand.jevPixelRect(JevBox(left: 0.5, top: 0.1, right: 0.75, bottom: 0.3), image: image)
        #expect(rect == JevVerdict.PixelRect(x: 1568, y: 100, width: 784, height: 200))
    }

    // MARK: Helpers

    private static func element(
        _ id: String,
        _ type: ElementType,
        label: String?,
        value: String? = nil,
        enabled: Bool = true
    ) -> DetectedElement {
        DetectedElement(
            id: id,
            type: type,
            label: label,
            value: value,
            bounds: CGRect(x: 0, y: 0, width: 40, height: 20),
            isEnabled: enabled,
            isSelected: nil,
            attributes: [:]
        )
    }

    private static func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
