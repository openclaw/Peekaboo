import CoreGraphics
import Foundation

struct ClickResult: Codable {
    let success: Bool
    let clickedElement: String?
    let clickLocation: [String: Double]
    let waitTime: Double
    let executionTime: TimeInterval
    let targetApp: String
    let targetWindowId: Int?
    let targetWindowTitle: String?
    let coordinateSpace: String?
    let inputCoordinates: [String: Double]?
    let screenCoordinates: [String: Double]?
    let targetPoint: InteractionTargetPointDiagnostics?

    init(
        success: Bool,
        clickedElement: String?,
        clickLocation: CGPoint,
        waitTime: Double,
        executionTime: TimeInterval,
        targetApp: String,
        targetWindowId: Int? = nil,
        targetWindowTitle: String? = nil,
        coordinateSpace: String? = nil,
        inputCoordinates: CGPoint? = nil,
        screenCoordinates: CGPoint? = nil,
        targetPoint: InteractionTargetPointDiagnostics? = nil
    ) {
        self.success = success
        self.clickedElement = clickedElement
        self.clickLocation = ["x": clickLocation.x, "y": clickLocation.y]
        self.waitTime = waitTime
        self.executionTime = executionTime
        self.targetApp = targetApp
        self.targetWindowId = targetWindowId
        self.targetWindowTitle = targetWindowTitle
        self.coordinateSpace = coordinateSpace
        self.inputCoordinates = inputCoordinates.map { ["x": $0.x, "y": $0.y] }
        self.screenCoordinates = screenCoordinates.map { ["x": $0.x, "y": $0.y] }
        self.targetPoint = targetPoint
    }
}
