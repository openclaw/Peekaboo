import Foundation
import PeekabooAutomation

/// A question for TypeSafe's Jev decision model.
///
/// Jev answers typed questions about a state instead of generating text: a
/// `choice` among named criteria, a `noul` yes/no probability, or a `box`
/// locating something in an attached image.
struct JevQuestion: Encodable, Equatable {
    enum Kind: String, Encodable {
        case choice
        case noul
        case box
    }

    let type: Kind
    let instructions: String
    let criteria: [String: String]?

    static func choice(_ instructions: String, criteria: [String: String]) -> JevQuestion {
        JevQuestion(type: .choice, instructions: instructions, criteria: criteria)
    }

    static func noul(_ instructions: String) -> JevQuestion {
        JevQuestion(type: .noul, instructions: instructions, criteria: nil)
    }

    static func box(_ instructions: String) -> JevQuestion {
        JevQuestion(type: .box, instructions: instructions, criteria: nil)
    }
}

struct JevAsset: Encodable, Equatable {
    let type = "image"
    let format = "png"
    let data_base64: String
}

struct JevRequest: Encodable, Equatable {
    let model: String
    let state: [String: String]
    let questions: [String: JevQuestion]
    let assets: [String: JevAsset]?

    /// Image and box requests use TypeSafe's opt-in experimental image support.
    var needsImageOptIn: Bool {
        self.assets != nil || self.questions.values.contains { $0.type == .box }
    }

    /// Builds a request, attaching `image` (PNG within Jev's bounds) under a
    /// unique reference that the state names as its picture.
    static func make(
        model: String,
        state: [String: String],
        questions: [String: JevQuestion],
        image: Data?
    ) -> JevRequest {
        guard let image else {
            return JevRequest(model: model, state: state, questions: questions, assets: nil)
        }
        // TypeSafe substitutes the reference wherever it occurs, so it must be
        // unique and appear nowhere else in the request.
        let reference = "peekaboo-image-" + UUID().uuidString.lowercased()
        var state = state
        state["picture"] = reference
        return JevRequest(
            model: model,
            state: state,
            questions: questions,
            assets: [reference: JevAsset(data_base64: image.base64EncodedString())]
        )
    }
}

struct JevBox: Decodable, Equatable {
    let left: Double
    let top: Double
    let right: Double
    let bottom: Double
}

/// One answer. A `noul` answer may arrive as a bare probability.
struct JevAnswer: Decodable, Equatable {
    var choice: String?
    var probabilities: [String: Double]?
    var confidence: Double?
    var noul: Double?
    var box: JevBox?

    private enum CodingKeys: String, CodingKey {
        case choice
        case probabilities
        case confidence
        case noul
        case box
    }

    init(
        choice: String? = nil,
        probabilities: [String: Double]? = nil,
        confidence: Double? = nil,
        noul: Double? = nil,
        box: JevBox? = nil
    ) {
        self.choice = choice
        self.probabilities = probabilities
        self.confidence = confidence
        self.noul = noul
        self.box = box
    }

    init(from decoder: any Decoder) throws {
        if let bare = try? decoder.singleValueContainer().decode(Double.self) {
            self.init(noul: bare)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            choice: container.decodeIfPresent(String.self, forKey: .choice),
            probabilities: container.decodeIfPresent([String: Double].self, forKey: .probabilities),
            confidence: container.decodeIfPresent(Double.self, forKey: .confidence),
            noul: container.decodeIfPresent(Double.self, forKey: .noul),
            box: container.decodeIfPresent(JevBox.self, forKey: .box)
        )
    }

    /// The chosen option's probability, and the best of the others.
    var choiceProbabilities: (probability: Double, runnerUp: Double)? {
        guard let choice else { return nil }
        let probabilities = self.probabilities ?? [:]
        let probability = probabilities[choice] ?? self.confidence ?? 0
        let runnerUp = probabilities.filter { $0.key != choice }.map(\.value).max() ?? 0
        return (probability, runnerUp)
    }
}

struct JevUsage: Codable, Equatable {
    let input_tokens: Int?
    let output_tokens: Int?
}

struct JevResponse: Decodable, Equatable {
    let answers: [String: JevAnswer]
    let usage: JevUsage?
}

/// A minimal client for Jev's `/v1/systemone` endpoint.
struct JevClient {
    enum JevError: Error, CustomStringConvertible {
        case missingKey
        case http(Int, String)
        case malformed(String)

        var description: String {
            switch self {
            case .missingKey:
                "No TypeSafe API key: set PEEKABOO_JEV_API_KEY or TYPESAFE_API_KEY, "
                    + "or add TYPESAFE_API_KEY to ~/.peekaboo/credentials"
            case let .http(status, body):
                "Jev answered HTTP \(status): \(body.prefix(400))"
            case let .malformed(detail):
                "Jev reply could not be read: \(detail)"
            }
        }
    }

    /// Jev's image bounds per side, in pixels.
    static let maxSide = 1568
    static let minSide = 280

    static let defaultModel = "jev-latest"
    /// Box answers come from the 1.14 model, which `jev-latest` may lag.
    static let defaultBoxModel = "jev-preview"

    let apiKey: String
    let model: String
    let boxModel: String
    let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    @MainActor
    static func configured(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> JevClient {
        guard let key = ConfigurationManager.shared.getTypeSafeAPIKey() else { throw JevError.missingKey }
        return JevClient(
            apiKey: key,
            model: environment["PEEKABOO_JEV_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? self.defaultModel,
            boxModel: environment["PEEKABOO_JEV_BOX_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? self.defaultBoxModel
        )
    }

    func ask(_ request: JevRequest) async throws -> JevResponse {
        var urlRequest = URLRequest(url: self.endpoint, timeoutInterval: 30)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(self.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if request.needsImageOptIn {
            urlRequest.setValue("true", forHTTPHeaderField: "TypeSafe-Danger-Zone-Images")
        }
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw JevError.http(status, Self.bodyText(data))
        }
        do {
            return try JSONDecoder().decode(JevResponse.self, from: data)
        } catch {
            throw JevError.malformed(Self.bodyText(data.prefix(400)))
        }
    }

    private static func bodyText(_ data: Data) -> String {
        String(bytes: data, encoding: .utf8) ?? "<\(data.count) bytes, not UTF-8>"
    }
}
