import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

// MARK: - Image Capture Models

/// Re-export PeekabooCore types
typealias SavedFile = PeekabooCore.SavedFile

/// Extend PeekabooCore types to conform to Commander argument parsing for CLI usage
extension PeekabooCore.CaptureMode: @retroactive ExpressibleFromArgument {
    public init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}

extension PeekabooCore.ImageFormat: @retroactive ExpressibleFromArgument {
    public init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}

extension PeekabooCore.CaptureFocus: @retroactive ExpressibleFromArgument {
    public init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}

// MARK: - Application & Window Models

// Re-export PeekabooCore types
typealias WindowInfo = PeekabooCore.WindowInfo
typealias WindowBounds = PeekabooCore.WindowBounds
typealias TargetApplicationInfo = PeekabooCore.TargetApplicationInfo
typealias WindowListData = PeekabooCore.WindowListData

// MARK: - Error Types

/// Re-export CaptureError from PeekabooFoundation
typealias CaptureError = PeekabooFoundation.CaptureError
