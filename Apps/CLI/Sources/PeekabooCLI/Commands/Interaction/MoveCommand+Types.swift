import CoreGraphics
import Foundation
import PeekabooCore

struct MoveResult: Codable {
    let success: Bool
    let targetLocation: [String: Double]
    let targetDescription: String
    let fromLocation: [String: Double]
    let distance: Double
    let duration: Int
    let smooth: Bool
    let profile: String
    let targetPoint: InteractionTargetPointDiagnostics?
    let executionTime: TimeInterval

    init(
        success: Bool,
        targetLocation: CGPoint,
        targetDescription: String,
        fromLocation: CGPoint,
        distance: Double,
        duration: Int,
        smooth: Bool,
        profile: String,
        targetPoint: InteractionTargetPointDiagnostics? = nil,
        executionTime: TimeInterval
    ) {
        self.success = success
        self.targetLocation = ["x": targetLocation.x, "y": targetLocation.y]
        self.targetDescription = targetDescription
        self.fromLocation = ["x": fromLocation.x, "y": fromLocation.y]
        self.distance = distance
        self.duration = duration
        self.smooth = smooth
        self.profile = profile
        self.targetPoint = targetPoint
        self.executionTime = executionTime
    }
}

struct MoveTargetResolution {
    let location: CGPoint
    let description: String
    let diagnostics: InteractionTargetPointDiagnostics?
}
