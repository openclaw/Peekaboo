import CoreGraphics
import Foundation
import PeekabooCore

extension MoveCommand {
    var selectedProfile: CursorMovementProfileSelection {
        guard let profileName = self.profile?.lowercased(),
              let selection = CursorMovementProfileSelection(rawValue: profileName) else {
            return self.smooth || (self.duration ?? 0) > 0 ? .human : .linear
        }
        return selection
    }

    func resolveMovementParameters(
        profileSelection: CursorMovementProfileSelection,
        distance: CGFloat
    ) -> CursorMovementParameters {
        CursorMovementResolver.resolve(
            CursorMovementResolutionRequest(
                selection: profileSelection,
                durationOverride: self.duration,
                stepsOverride: self.steps,
                baseSmooth: self.smooth || self.duration != nil,
                distance: distance,
                defaultDuration: 500,
                defaultSteps: 20
            )
        )
    }
}
