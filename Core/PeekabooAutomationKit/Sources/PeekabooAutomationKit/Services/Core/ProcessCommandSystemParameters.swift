import Foundation

extension ProcessCommandParameters {
    public struct LaunchAppParameters: Codable, Sendable {
        public let appName: String
        public let action: String?
        public let waitForLaunch: Bool?
        public let bringToFront: Bool?
        public let force: Bool?

        public init(
            appName: String,
            action: String? = nil,
            waitForLaunch: Bool? = nil,
            bringToFront: Bool? = nil,
            force: Bool? = nil)
        {
            self.appName = appName
            self.action = action
            self.waitForLaunch = waitForLaunch
            self.bringToFront = bringToFront
            self.force = force
        }
    }

    public struct ScreenshotParameters: Codable, Sendable {
        public let path: String
        public let app: String?
        public let pid: Int32?
        public let windowId: Int?
        public let window: String?
        public let display: Int?
        public let mode: String?
        public let annotate: Bool?

        public init(
            path: String,
            app: String? = nil,
            pid: Int32? = nil,
            windowId: Int? = nil,
            window: String? = nil,
            display: Int? = nil,
            mode: String? = nil,
            annotate: Bool? = nil)
        {
            self.path = path
            self.app = app
            self.pid = pid
            self.windowId = windowId
            self.window = window
            self.display = display
            self.mode = mode
            self.annotate = annotate
        }
    }

    public struct FocusWindowParameters: Codable, Sendable {
        public let app: String?
        public let title: String?
        public let index: Int?

        public init(app: String? = nil, title: String? = nil, index: Int? = nil) {
            self.app = app
            self.title = title
            self.index = index
        }
    }

    public struct ResizeWindowParameters: Codable, Sendable {
        public let width: Int?
        public let height: Int?
        public let x: Int?
        public let y: Int?
        public let app: String?
        public let maximize: Bool?
        public let minimize: Bool?

        public init(
            width: Int? = nil,
            height: Int? = nil,
            x: Int? = nil,
            y: Int? = nil,
            app: String? = nil,
            maximize: Bool? = nil,
            minimize: Bool? = nil)
        {
            self.width = width
            self.height = height
            self.x = x
            self.y = y
            self.app = app
            self.maximize = maximize
            self.minimize = minimize
        }
    }

    public struct SleepParameters: Codable, Sendable {
        public let duration: Double

        public init(duration: Double) {
            self.duration = duration
        }
    }

    public struct DockParameters: Codable, Sendable {
        public let action: String
        public let item: String?
        public let path: String?

        public init(action: String, item: String? = nil, path: String? = nil) {
            self.action = action
            self.item = item
            self.path = path
        }
    }

    public struct ClipboardParameters: Codable, Sendable {
        public let action: String
        public let text: String?
        public let filePath: String?
        public let dataBase64: String?
        public let uti: String?
        public let prefer: String?
        public let output: String?
        public let slot: String?
        public let alsoText: String?
        public let allowLarge: Bool?

        public init(
            action: String,
            text: String? = nil,
            filePath: String? = nil,
            dataBase64: String? = nil,
            uti: String? = nil,
            prefer: String? = nil,
            output: String? = nil,
            slot: String? = nil,
            alsoText: String? = nil,
            allowLarge: Bool? = nil)
        {
            self.action = action
            self.text = text
            self.filePath = filePath
            self.dataBase64 = dataBase64
            self.uti = uti
            self.prefer = prefer
            self.output = output
            self.slot = slot
            self.alsoText = alsoText
            self.allowLarge = allowLarge
        }
    }
}
