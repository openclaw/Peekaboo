import Foundation
import PeekabooCore

struct DragResult: Codable {
    let from: [String: Int]
    let to: [String: Int]
    let duration: Int
    let steps: Int
    let profile: String
    let modifiers: String
    let button: String
    let fromTargetPoint: InteractionTargetPointDiagnostics?
    let toTargetPoint: InteractionTargetPointDiagnostics?
    let executionTime: TimeInterval
}
