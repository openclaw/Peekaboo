import CoreGraphics
import Foundation
import PeekabooCore

enum CursorMovementProfileSelection: String {
    case linear
    case human
}

struct CursorMovementParameters {
    let profile: MouseMovementProfile
    let duration: Int
    let steps: Int
    let smooth: Bool
    let profileName: String
}

struct CursorMovementResolutionRequest {
    let selection: CursorMovementProfileSelection
    let durationOverride: Int?
    let stepsOverride: Int?
    let baseSmooth: Bool
    let distance: CGFloat
    let defaultDuration: Int
    let defaultSteps: Int
}

enum CursorMovementResolver {
    static func resolve(_ request: CursorMovementResolutionRequest) -> CursorMovementParameters {
        switch request.selection {
        case .linear:
            let resolvedDuration = request.durationOverride ?? (request.baseSmooth ? request.defaultDuration : 0)
            let resolvedSteps = request.baseSmooth ? max(request.stepsOverride ?? request.defaultSteps, 1) : 1
            return CursorMovementParameters(
                profile: .linear,
                duration: resolvedDuration,
                steps: resolvedSteps,
                smooth: request.baseSmooth,
                profileName: request.selection.rawValue
            )
        case .human:
            let resolvedDuration = request.durationOverride ?? Self.humanDuration(for: request.distance)
            let resolvedSteps = max(request.stepsOverride ?? Self.humanSteps(for: request.distance), 1)
            return CursorMovementParameters(
                profile: .human(),
                duration: resolvedDuration,
                steps: resolvedSteps,
                smooth: true,
                profileName: request.selection.rawValue
            )
        }
    }

    private static func humanDuration(for distance: CGFloat) -> Int {
        let distanceFactor = log2(Double(distance) + 1) * 90
        let perPixel = Double(distance) * 0.45
        let estimate = 280 + distanceFactor + perPixel
        return min(max(Int(estimate), 300), 1700)
    }

    private static func humanSteps(for distance: CGFloat) -> Int {
        let scaled = Int(distance * 0.22)
        return min(max(scaled, 30), 96)
    }
}
