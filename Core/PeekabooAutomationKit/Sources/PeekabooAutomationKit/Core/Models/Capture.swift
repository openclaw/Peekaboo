import Foundation

// MARK: - Image capture primitives (shared with screenshot paths)

public struct SavedFile: Codable, Sendable {
    public let path: String
    public let item_label: String?
    public let window_title: String?
    public let window_id: UInt32?
    public let window_index: Int?
    public let mime_type: String

    public init(
        path: String,
        item_label: String? = nil,
        window_title: String? = nil,
        window_id: UInt32? = nil,
        window_index: Int? = nil,
        mime_type: String)
    {
        self.path = path
        self.item_label = item_label
        self.window_title = window_title
        self.window_id = window_id
        self.window_index = window_index
        self.mime_type = mime_type
    }
}

public enum CaptureMode: String, CaseIterable, Codable, Sendable, Equatable {
    case screen
    case window
    case multi
    case frontmost
    case area
}

public enum ImageFormat: String, CaseIterable, Codable, Sendable, Equatable {
    case png
    case jpg
}

public enum CaptureFocus: String, CaseIterable, Codable, Sendable, Equatable {
    case background
    case auto
    case foreground
}

// Back-compat typealiases (temporary; remove after downstream migration)
public typealias WatchCaptureOptions = CaptureOptions
public typealias WatchStats = CaptureStats
public typealias WatchContactSheet = CaptureContactSheet
public typealias WatchWarning = CaptureWarning
