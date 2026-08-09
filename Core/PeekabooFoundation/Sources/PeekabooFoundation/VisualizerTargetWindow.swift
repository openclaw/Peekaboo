import CoreGraphics
import Foundation

/// The window an automation event was delivered to.
///
/// Frames use global Core Graphics / Accessibility coordinates. Visualizer
/// clients convert them to AppKit coordinates at the process boundary.
public struct VisualizerTargetWindow: Codable, Equatable, Sendable {
    public let processIdentifier: Int32
    public let windowID: UInt32
    public let frame: CGRect

    public init(processIdentifier: Int32, windowID: UInt32, frame: CGRect) {
        self.processIdentifier = processIdentifier
        self.windowID = windowID
        self.frame = frame
    }
}
