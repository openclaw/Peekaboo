import CoreGraphics
import Foundation
import ImageIO
import PeekabooCore
import PeekabooFoundation
import UniformTypeIdentifiers

/// The answer `see --jev-pick|--jev-check|--jev-locate` prints instead of the
/// element map.
struct JevVerdict: Codable, Equatable {
    struct PixelRect: Codable, Equatable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    let mode: String
    let snapshot_id: String?
    var element_id: String?
    var description: String?
    var actionable: Bool?
    var probability: Double?
    var runner_up: Double?
    var confident: Bool?
    var candidates: Int?
    var statement: String?
    var yes: Double?
    var box_pixels: PixelRect?
    var box_confidence: Double?
    var visible: Double?
    var image_sent: Bool
    var jev_ms: Int = 0
    var usage: JevUsage?
}

/// Jev-backed verdicts over one observation.
///
/// The caller gets one short answer instead of the element map or the
/// screenshot: the element a description means, the probability that a
/// statement about the window is true, or a box around something visible. Jev
/// reads the tree and the image, so the caller reads tens of tokens. Verdicts
/// report their confidence and never act; the caller decides what an
/// uncertain answer means.
@available(macOS 14.0, *)
@MainActor
extension SeeCommand {
    var requestsJev: Bool {
        self.jevPick != nil || self.jevCheck != nil || self.jevLocate != nil
    }

    /// Prints a Jev verdict when one was requested, and the usual results otherwise.
    func renderObservation(context: SeeCommandRenderContext) async throws {
        if self.requestsJev {
            try await self.renderJevResults(context: context)
        } else {
            try self.renderResults(context: context)
        }
    }

    func renderJevResults(context: SeeCommandRenderContext) async throws {
        let client = try JevClient.configured()
        let observation = try JevObservation(
            application: context.metadata.windowContext?.applicationName ?? "unknown",
            window: context.metadata.windowContext?.windowTitle ?? "",
            elements: context.elements.all,
            image: context.screenshotData.map(Self.fitForJev),
            snapshotID: context.snapshotReusable ? context.snapshotId : nil
        )
        let started = Date()

        var verdict: JevVerdict
        let line: String
        if let target = self.jevPick {
            (verdict, line) = try await Self.jevPick(target, observation: observation, client: client)
        } else if let statement = self.jevCheck {
            (verdict, line) = try await Self.jevCheck(statement, observation: observation, client: client)
        } else if let target = self.jevLocate {
            (verdict, line) = try await Self.jevLocate(target, observation: observation, client: client)
        } else {
            return
        }
        verdict.jev_ms = Int(Date().timeIntervalSince(started) * 1000)

        if self.jsonOutput {
            try self.outputSeeSuccessJSON(data: verdict, receipt: context.receipt)
        } else {
            try context.receipt.requirePublishableOutcome(
                operation: "See",
                requiresOutcome: self.webFocus || self.menubar
            )
            let snapshot = observation.snapshotID.map { " snapshot=\($0)" } ?? ""
            print(line + snapshot + " jev_ms=\(verdict.jev_ms)")
        }
    }

    private static func jevPick(
        _ target: String,
        observation: JevObservation,
        client: JevClient
    ) async throws -> (JevVerdict, String) {
        let candidates = self.jevCandidates(observation.elements)
        guard !candidates.isEmpty else {
            throw PeekabooError.operationError(message: "No elements to choose from")
        }
        var state = ["application": observation.application, "window": observation.window, "request": target]
        if observation.image != nil {
            state["image"] = "The image is the app's window. Element positions are in its pixels."
        }
        let criteria = Dictionary(uniqueKeysWithValues: candidates.map { ($0.element.id, $0.description) })
        let request = JevRequest.make(
            model: client.model,
            state: state,
            questions: ["target": .choice(
                "Which interface element is the one this request refers to: \"\(target)\"?",
                criteria: criteria
            )],
            image: observation.image?.png
        )
        let response = try await client.ask(request)
        guard let answer = response.answers["target"], let odds = answer.choiceProbabilities,
              let chosen = candidates.first(where: { $0.element.id == answer.choice })
        else { throw JevClient.JevError.malformed("no choice among the candidates") }

        let confident = self.jevConfident(probability: odds.probability, runnerUp: odds.runnerUp)
        var verdict = JevVerdict(
            mode: "pick",
            snapshot_id: observation.snapshotID,
            image_sent: observation.image != nil
        )
        verdict.element_id = chosen.element.id
        verdict.description = chosen.description
        verdict.actionable = chosen.element.isActionable
        verdict.probability = self.rounded(odds.probability)
        verdict.runner_up = self.rounded(odds.runnerUp)
        verdict.confident = confident
        verdict.candidates = candidates.count
        verdict.usage = response.usage
        let flag = chosen.element.isActionable ? "" : " not-actionable"
        let line = "\(confident ? "PICK" : "UNSURE") \(chosen.element.id) \(chosen.description)\(flag)"
            + " p=\(self.rounded(odds.probability)) next=\(self.rounded(odds.runnerUp))"
        return (verdict, line)
    }

    private static func jevCheck(
        _ statement: String,
        observation: JevObservation,
        client: JevClient
    ) async throws -> (JevVerdict, String) {
        var state = [
            "application": observation.application,
            "window": observation.window,
            "tree": self.jevTreeText(observation.elements),
        ]
        if observation.image != nil {
            state["image"] = "The image is the app's window as it is now."
        }
        let request = JevRequest.make(
            model: client.model,
            state: state,
            questions: ["check": .noul(statement)],
            image: observation.image?.png
        )
        let response = try await client.ask(request)
        guard let yes = response.answers["check"]?.noul else {
            throw JevClient.JevError.malformed("no yes/no answer")
        }
        var verdict = JevVerdict(
            mode: "check",
            snapshot_id: observation.snapshotID,
            image_sent: observation.image != nil
        )
        verdict.statement = statement
        verdict.yes = self.rounded(yes)
        verdict.usage = response.usage
        return (verdict, "\(yes >= 0.5 ? "YES" : "NO") p_yes=\(self.rounded(yes))")
    }

    private static func jevLocate(
        _ target: String,
        observation: JevObservation,
        client: JevClient
    ) async throws -> (JevVerdict, String) {
        guard let image = observation.image else {
            throw PeekabooError.operationError(message: "--jev-locate needs the screenshot")
        }
        let request = JevRequest.make(
            model: client.boxModel,
            state: [
                "application": observation.application,
                "window": observation.window,
                "request": target,
                "image": "The image is the app's window.",
            ],
            questions: [
                "where": .box("Where in the picture is: \"\(target)\""),
                // A box answer always has a box, so presence is its own question.
                "there": .noul("Is this visible in the picture: \"\(target)\"?"),
            ],
            image: image.png
        )
        let response = try await client.ask(request)
        guard let answer = response.answers["where"], let box = answer.box else {
            throw JevClient.JevError.malformed("no box")
        }
        let visible = response.answers["there"]?.noul ?? 0
        let confidence = self.rounded(answer.confidence ?? 0)
        let rect = self.jevPixelRect(box, image: image)
        var verdict = JevVerdict(mode: "locate", snapshot_id: observation.snapshotID, image_sent: true)
        verdict.box_pixels = rect
        verdict.box_confidence = confidence
        verdict.visible = self.rounded(visible)
        verdict.usage = response.usage
        let line = "\(visible >= 0.5 ? "FOUND" : "ABSENT") x=\(rect.x) y=\(rect.y) w=\(rect.width) h=\(rect.height)"
            + " conf=\(confidence) visible=\(self.rounded(visible))"
        return (verdict, line)
    }
}

// MARK: - Pure helpers

@available(macOS 14.0, *)
extension SeeCommand {
    struct JevCandidate {
        let element: DetectedElement
        let description: String
    }

    /// What every Jev question is asked about: one observation of one window.
    struct JevObservation {
        let application: String
        let window: String
        let elements: [DetectedElement]
        let image: JevImage?
        let snapshotID: String?
    }

    struct JevImage {
        let png: Data
        /// Capture pixels per sent pixel.
        let scale: Double
        let sentWidth: Int
        let sentHeight: Int
    }

    /// Element types a person names as targets even when Peekaboo does not
    /// mark them actionable: disabled controls and labelled groups such as
    /// list rows.
    static let jevControlTypes: Set<ElementType> = [
        .button, .textField, .link, .image, .group, .slider, .checkbox, .radioButton, .menuItem,
    ]

    /// The acceptance rule: sure on its own, or clearly ahead of the runner-up.
    static func jevConfident(probability: Double, runnerUp: Double) -> Bool {
        probability >= 0.6 || (probability >= 0.5 && probability >= 2 * runnerUp)
    }

    /// Anything a person could name as a target, described the way they would
    /// name it. `isActionable` alone is too strict for choosing: "the Send
    /// button" must resolve to the disabled Send button, not a lookalike. Jev
    /// caps one question at 255 options; tree order keeps the first ones.
    static func jevCandidates(_ elements: [DetectedElement]) -> [JevCandidate] {
        elements
            .filter { element in
                let labelled = !(element.label ?? element.attributes["description"] ?? "").isEmpty
                return element.isActionable || (labelled && self.jevControlTypes.contains(element.type))
            }
            .prefix(255)
            .map { element in
                let state = element.knownIsEnabled == false ? " disabled" : ""
                return JevCandidate(element: element, description: self.jevDescribe(element) + state)
            }
    }

    static func jevDescribe(_ element: DetectedElement) -> String {
        var parts = [element.type.rawValue]
        let label = element.label ?? element.attributes["title"]
        if let label, !label.isEmpty {
            parts.append("\"\(label)\"")
        }
        if let description = element.attributes["description"], description != label, !description.isEmpty {
            parts.append("desc=\"\(description.prefix(80))\"")
        }
        if let value = element.value, !value.isEmpty {
            parts.append("value=\"\(value.prefix(60))\"")
        }
        return parts.joined(separator: " ")
    }

    static func jevTreeText(_ elements: [DetectedElement]) -> String {
        elements.prefix(400).map { element in
            let state = element.knownIsEnabled == false ? " disabled" : ""
            return "\(element.id) \(self.jevDescribe(element))\(state)"
        }.joined(separator: "\n")
    }

    /// Maps a box in fractions of the sent image back to capture pixels. The
    /// sent image differs from the capture only by a scale and by padding at
    /// the bottom and right.
    static func jevPixelRect(_ box: JevBox, image: JevImage) -> JevVerdict.PixelRect {
        let width = Double(image.sentWidth) * image.scale
        let height = Double(image.sentHeight) * image.scale
        return JevVerdict.PixelRect(
            x: Int((box.left * width).rounded()),
            y: Int((box.top * height).rounded()),
            width: Int(((box.right - box.left) * width).rounded()),
            height: Int(((box.bottom - box.top) * height).rounded())
        )
    }

    /// Shrinks the capture until its longer side fits Jev's bound, then pads
    /// the bottom and right until its shorter side does.
    static func fitForJev(_ data: Data) throws -> JevImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw JevClient.JevError.malformed("screenshot is not an image") }
        let longest = max(image.width, image.height)
        let scale = longest > JevClient.maxSide ? Double(longest) / Double(JevClient.maxSide) : 1
        let drawnWidth = Int((Double(image.width) / scale).rounded())
        let drawnHeight = Int((Double(image.height) / scale).rounded())
        let width = max(drawnWidth, JevClient.minSide)
        let height = max(drawnHeight, JevClient.minSide)
        if scale == 1, width == image.width, height == image.height {
            return JevImage(png: data, scale: 1, sentWidth: width, sentHeight: height)
        }
        guard let canvas = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw JevClient.JevError.malformed("could not resize the screenshot") }
        canvas.setFillColor(CGColor(gray: 0, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        canvas.interpolationQuality = .high
        // Core Graphics draws bottom-up: anchor the image at the top left.
        canvas.draw(image, in: CGRect(x: 0, y: height - drawnHeight, width: drawnWidth, height: drawnHeight))
        guard let resized = canvas.makeImage() else {
            throw JevClient.JevError.malformed("could not resize the screenshot")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { throw JevClient.JevError.malformed("could not encode the screenshot") }
        CGImageDestinationAddImage(destination, resized, nil)
        CGImageDestinationFinalize(destination)
        return JevImage(png: output as Data, scale: scale, sentWidth: width, sentHeight: height)
    }

    static func rounded(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }
}
