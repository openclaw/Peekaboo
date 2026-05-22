import CoreGraphics
import Foundation

/// Detects UI elements in SDL/GPU-rendered game windows by reading a JSON
/// accessibility manifest that the game writes each frame.
///
/// Protocol: the game writes `~/.{appname}/accessibility.json` atomically.
/// Peekaboo reads this file during element detection when the target window
/// belongs to a known game-bridge app.
///
/// This avoids relying on macOS Accessibility API (which doesn't see into
/// GPU-rendered content) while still allowing `peekaboo see`, `peekaboo click`,
/// and other automation commands to work with game windows.
@available(macOS 14.0, *)
public final class GameBridgeDetectionService: Sendable {
    /// Known game-bridge apps and their manifest paths.
    /// The path is relative to the user's home directory.
    private static let knownApps: [String: String] = [
        "firestaff": ".firestaff/accessibility.json",
        "Firestaff": ".firestaff/accessibility.json",
    ]

    /// Manifest JSON structure matching Firestaff's accessibility output
    public struct GameManifest: Codable, Sendable {
        public let version: Int
        public let app: String
        public let gameState: String
        public let framebuffer: FramebufferSize
        public let elements: [GameElement]

        public struct FramebufferSize: Codable, Sendable {
            public let width: Int
            public let height: Int
        }

        public struct GameElement: Codable, Sendable {
            public let id: String
            public let type: String
            public let label: String?
            public let bounds: Bounds
            public let enabled: Bool
            public let value: String?

            private enum CodingKeys: String, CodingKey {
                case id
                case type
                case label
                case bounds
                case enabled
                case value
            }

            public init(
                id: String,
                type: String,
                label: String?,
                bounds: Bounds,
                enabled: Bool = true,
                value: String? = nil)
            {
                self.id = id
                self.type = type
                self.label = label
                self.bounds = bounds
                self.enabled = enabled
                self.value = value
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.id = try container.decode(String.self, forKey: .id)
                self.type = try container.decode(String.self, forKey: .type)
                self.label = try container.decodeIfPresent(String.self, forKey: .label)
                self.bounds = try container.decode(Bounds.self, forKey: .bounds)
                self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
                self.value = try container.decodeIfPresent(String.self, forKey: .value)
            }

            public struct Bounds: Codable, Sendable {
                public let x: Int
                public let y: Int
                public let w: Int
                public let h: Int

                public init(x: Int, y: Int, w: Int, h: Int) {
                    self.x = x
                    self.y = y
                    self.w = w
                    self.h = h
                }

                public var cgRect: CGRect {
                    CGRect(x: self.x, y: self.y, width: self.w, height: self.h)
                }
            }
        }
    }

    /// Check if a window belongs to a game-bridge app
    public static func isGameBridgeApp(appName: String?) -> Bool {
        guard let name = appName else { return false }
        return self.knownApps[name] != nil
    }

    /// Read the accessibility manifest for a game-bridge app.
    public static func readManifest(
        appName: String,
        manifestRootURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date(),
        maxManifestAge: TimeInterval = 5) -> GameManifest?
    {
        guard let relativePath = knownApps[appName] else { return nil }
        let manifestURL = manifestRootURL.appendingPathComponent(relativePath)

        guard self.isFreshManifest(at: manifestURL, now: now, maxAge: maxManifestAge) else { return nil }
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(GameManifest.self, from: data)
    }

    private static func isFreshManifest(at url: URL, now: Date, maxAge: TimeInterval) -> Bool {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let modificationDate = attributes[.modificationDate] as? Date
        else {
            return false
        }

        return now.timeIntervalSince(modificationDate) <= maxAge
    }

    /// Convert game manifest elements to Peekaboo DetectedElements
    public static func detectElements(
        from manifest: GameManifest,
        windowBounds: CGRect?) -> [GameBridgeDetectedElement]
    {
        let scaleX: CGFloat
        let scaleY: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat

        if let wb = windowBounds {
            // Scale framebuffer coordinates to window coordinates
            scaleX = wb.width / CGFloat(manifest.framebuffer.width)
            scaleY = wb.height / CGFloat(manifest.framebuffer.height)
            offsetX = wb.origin.x
            offsetY = wb.origin.y
        } else {
            scaleX = 1
            scaleY = 1
            offsetX = 0
            offsetY = 0
        }

        return manifest.elements.map { element in
            let scaledBounds = CGRect(
                x: CGFloat(element.bounds.x) * scaleX + offsetX,
                y: CGFloat(element.bounds.y) * scaleY + offsetY,
                width: CGFloat(element.bounds.w) * scaleX,
                height: CGFloat(element.bounds.h) * scaleY)

            return GameBridgeDetectedElement(
                id: element.id,
                type: self.mapElementType(element.type),
                label: element.label,
                value: element.value,
                bounds: scaledBounds,
                enabled: element.enabled,
                framebufferBounds: element.bounds.cgRect,
                gameState: manifest.gameState)
        }
    }

    /// Map game element type strings to Peekaboo-compatible types
    private static func mapElementType(_ gameType: String) -> String {
        switch gameType {
        case "button", "movement", "dialogChoice":
            "button"
        case "slot", "portrait", "championMirror":
            "image"
        case "text":
            "staticText"
        case "region":
            "group"
        default:
            "other"
        }
    }
}

/// A detected element from a game bridge manifest
public struct GameBridgeDetectedElement: Sendable {
    public let id: String
    public let type: String
    public let label: String?
    public let value: String?
    public let bounds: CGRect // Screen coordinates
    public let enabled: Bool
    public let framebufferBounds: CGRect // Original game framebuffer coords
    public let gameState: String
}
