import Foundation

struct TypeCommandResult: Codable {
    let requestedText: String?
    let typedText: String?
    let keyPresses: Int
    let totalCharacters: Int
    let literalCharactersTyped: Int
    let specialKeyPresses: Int
    let actions: [TypeCommandActionSummary]
    let executionTime: TimeInterval
    let wordsPerMinute: Int?
    let profile: String
    let deliveryMode: String
    let targetPID: Int?
    let targetWindowID: Int?
}

struct TypeCommandActionSummary: Codable {
    let kind: String
    let value: String?
}
