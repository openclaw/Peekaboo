import Foundation

extension ProcessCommandParameters {
    public struct ClickParameters: Codable, Sendable {
        public let x: Double?
        public let y: Double?
        public let label: String?
        public let app: String?
        public let pid: Int32?
        public let windowId: Int?
        public let snapshot: String?
        public let foreground: Bool?
        public let button: String?
        public let modifiers: [String]?

        public init(
            x: Double? = nil,
            y: Double? = nil,
            label: String? = nil,
            app: String? = nil,
            pid: Int32? = nil,
            windowId: Int? = nil,
            snapshot: String? = nil,
            foreground: Bool? = nil,
            button: String? = nil,
            modifiers: [String]? = nil)
        {
            self.x = x
            self.y = y
            self.label = label
            self.app = app
            self.pid = pid
            self.windowId = windowId
            self.snapshot = snapshot
            self.foreground = foreground
            self.button = button
            self.modifiers = modifiers
        }
    }

    public struct TypeParameters: Codable, Sendable {
        public let text: String
        public let app: String?
        public let pid: Int32?
        public let windowId: Int?
        public let snapshot: String?
        public let foreground: Bool?
        public let field: String?
        public let clearFirst: Bool?
        public let pressEnter: Bool?

        public init(
            text: String,
            app: String? = nil,
            pid: Int32? = nil,
            windowId: Int? = nil,
            snapshot: String? = nil,
            foreground: Bool? = nil,
            field: String? = nil,
            clearFirst: Bool? = nil,
            pressEnter: Bool? = nil)
        {
            self.text = text
            self.app = app
            self.pid = pid
            self.windowId = windowId
            self.snapshot = snapshot
            self.foreground = foreground
            self.field = field
            self.clearFirst = clearFirst
            self.pressEnter = pressEnter
        }
    }

    public struct HotkeyParameters: Codable, Sendable {
        public let key: String
        public let modifiers: [String]
        public let app: String?
        public let pid: Int32?
        public let windowId: Int?
        public let snapshot: String?
        public let foreground: Bool?

        public init(
            key: String,
            modifiers: [String],
            app: String? = nil,
            pid: Int32? = nil,
            windowId: Int? = nil,
            snapshot: String? = nil,
            foreground: Bool? = nil)
        {
            self.key = key
            self.modifiers = modifiers
            self.app = app
            self.pid = pid
            self.windowId = windowId
            self.snapshot = snapshot
            self.foreground = foreground
        }
    }

    public struct ScrollParameters: Codable, Sendable {
        public let direction: String
        public let amount: Int?
        public let app: String?
        public let pid: Int32?
        public let windowId: Int?
        public let snapshot: String?
        public let foreground: Bool?
        public let target: String?

        public init(
            direction: String,
            amount: Int? = nil,
            app: String? = nil,
            pid: Int32? = nil,
            windowId: Int? = nil,
            snapshot: String? = nil,
            foreground: Bool? = nil,
            target: String? = nil)
        {
            self.direction = direction
            self.amount = amount
            self.app = app
            self.pid = pid
            self.windowId = windowId
            self.snapshot = snapshot
            self.foreground = foreground
            self.target = target
        }
    }

    public struct MenuClickParameters: Codable, Sendable {
        public let menuPath: [String]
        public let app: String?

        public init(menuPath: [String], app: String? = nil) {
            self.menuPath = menuPath
            self.app = app
        }
    }

    public struct DialogParameters: Codable, Sendable {
        public let action: String
        public let buttonLabel: String?
        public let inputText: String?
        public let fieldLabel: String?

        public init(action: String, buttonLabel: String? = nil, inputText: String? = nil, fieldLabel: String? = nil) {
            self.action = action
            self.buttonLabel = buttonLabel
            self.inputText = inputText
            self.fieldLabel = fieldLabel
        }
    }

    public struct FindElementParameters: Codable, Sendable {
        public let label: String?
        public let identifier: String?
        public let type: String?
        public let app: String?

        public init(label: String? = nil, identifier: String? = nil, type: String? = nil, app: String? = nil) {
            self.label = label
            self.identifier = identifier
            self.type = type
            self.app = app
        }
    }

    public struct SwipeParameters: Codable, Sendable {
        public let direction: String
        public let distance: Double?
        public let duration: Double?
        public let fromX: Double?
        public let fromY: Double?
        public let foreground: Bool?

        public init(
            direction: String,
            distance: Double? = nil,
            duration: Double? = nil,
            fromX: Double? = nil,
            fromY: Double? = nil,
            foreground: Bool? = nil)
        {
            self.direction = direction
            self.distance = distance
            self.duration = duration
            self.fromX = fromX
            self.fromY = fromY
            self.foreground = foreground
        }
    }

    public struct DragParameters: Codable, Sendable {
        public let fromX: Double
        public let fromY: Double
        public let toX: Double
        public let toY: Double
        public let duration: Double?
        public let modifiers: [String]?
        public let foreground: Bool?

        public init(
            fromX: Double,
            fromY: Double,
            toX: Double,
            toY: Double,
            duration: Double? = nil,
            modifiers: [String]? = nil,
            foreground: Bool? = nil)
        {
            self.fromX = fromX
            self.fromY = fromY
            self.toX = toX
            self.toY = toY
            self.duration = duration
            self.modifiers = modifiers
            self.foreground = foreground
        }
    }
}
