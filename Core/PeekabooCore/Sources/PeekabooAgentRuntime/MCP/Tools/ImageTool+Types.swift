import Foundation
import MCP
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

/// Extended format that includes "data" option
enum ImageFormatOption: String, Codable {
    case png
    case jpg
    case data // Return as base64 data
}

struct ImageInput: Codable {
    let path: String?
    let format: ImageFormatOption?
    let appTarget: String?
    let windowID: Int?
    let captureFocus: CaptureFocus?
    let scale: String?
    let retina: Bool?
    let maxDimension: Int?

    enum CodingKeys: String, CodingKey {
        case path, format, scale, retina
        case appTarget = "app_target"
        case windowID = "window_id"
        case captureFocus = "capture_focus"
        case maxDimension = "max_dimension"
    }
}

struct ImageRequest {
    let path: String?
    let format: ImageFormatOption
    let target: ObservationTargetArgument
    let captureFocus: CaptureFocus
    let scale: CaptureScalePreference
    let maxDimension: Int?

    init(arguments: ToolArguments) throws {
        let input = try arguments.decode(ImageInput.self)
        self.path = input.path
        self.captureFocus = input.captureFocus ?? .background
        self.format = input.format ?? .png
        self.target = try ObservationTargetArgument.parse(
            input.appTarget,
            windowIDValue: input.windowID.map(Value.int))
        self.scale = try Self.captureScale(scale: input.scale, retina: input.retina)
        if let maxDim = input.maxDimension {
            guard maxDim > 0 else {
                throw PeekabooError.invalidInput("max_dimension must be a positive integer.")
            }
            self.maxDimension = maxDim
        } else {
            self.maxDimension = nil
        }
    }

    private static func captureScale(scale: String?, retina: Bool?) throws -> CaptureScalePreference {
        if retina == true {
            return .native
        }

        guard let scale else {
            return .logical1x
        }

        switch scale.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "logical", "logical1x", "1x":
            return .logical1x
        case "native", "retina", "2x":
            return .native
        default:
            throw PeekabooError.invalidInput("Invalid image scale: \(scale)")
        }
    }
}

extension ImageRequest {
    var effectiveMaxDimension: Int? {
        self.maxDimension ?? (self.format == .data ? 1500 : nil)
    }

    var focusIdentifier: String? {
        self.target.focusIdentifier
    }

    var exactWindowID: Int? {
        switch self.target {
        case let .windowID(windowID):
            Int(windowID)
        case let .application(_, .id(windowID)), let .pid(_, .id(windowID)):
            Int(windowID)
        case .screen, .frontmost, .application, .pid, .menubar:
            nil
        }
    }

    var requiresExactWindowTarget: Bool {
        switch self.target {
        case .frontmost, .application, .pid, .windowID:
            true
        case .screen, .menubar:
            false
        }
    }

    func observationTarget(
        pinnedTo activatedIdentity: ApplicationProcessIdentity?) -> DesktopObservationTargetRequest
    {
        guard let activatedIdentity else { return self.target.observationTarget }
        guard case let .application(_, window) = self.target else {
            return self.target.observationTarget
        }
        return .pid(activatedIdentity.processIdentifier, window: window)
    }

    var outputPath: String? {
        guard let path else {
            return nil
        }
        return ObservationOutputPathResolver.resolve(
            path: path,
            format: self.format.imageFormat,
            defaultFileName: "peekaboo-\(UUID().uuidString).\(self.format.fileExtension)",
            replacingExistingExtension: true).path
    }
}

func saveTemporaryImage(_ data: Data) throws -> String {
    let tempDir = FileManager.default.temporaryDirectory
    let fileName = "peekaboo-\(UUID().uuidString).png"
    let url = tempDir.appendingPathComponent(fileName)
    try data.write(to: url)
    return url.path
}

func describeCapture(_ metadata: CaptureMetadata) -> String {
    if let appInfo = metadata.applicationInfo {
        if let windowInfo = metadata.windowInfo {
            return "\(appInfo.name) - \(windowInfo.title)"
        }
        return appInfo.name
    }

    if let displayInfo = metadata.displayInfo {
        return "Screen \(displayInfo.index)"
    }

    return "Screenshot"
}

func buildImageSummary(savedFiles: [MCPSavedFile], captureCount: Int) -> String {
    if savedFiles.isEmpty {
        return "Captured \(captureCount) image(s)"
    }

    var lines: [String] = []
    lines.append("📸 Captured \(captureCount) screenshot(s)")

    for file in savedFiles {
        lines.append("  • \(file.item_label): \(file.path)")
    }

    return lines.joined(separator: "\n")
}

struct MCPSavedFile {
    let path: String
    let item_label: String
    let window_title: String?
    let window_id: String?
    let window_index: Int?
    let mime_type: String
}

extension ImageFormatOption {
    var mimeType: String {
        switch self {
        case .png, .data: "image/png"
        case .jpg: "image/jpeg"
        }
    }

    var fileExtension: String {
        switch self {
        case .png, .data: "png"
        case .jpg: "jpg"
        }
    }

    /// Convert to ImageFormat for actual image saving
    var imageFormat: ImageFormat {
        switch self {
        case .png, .data: .png
        case .jpg: .jpg
        }
    }
}
