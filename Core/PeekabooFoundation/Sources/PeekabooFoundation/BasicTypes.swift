//
//  BasicTypes.swift
//  PeekabooFoundation
//

import Foundation

// MARK: - Element Types

/// Type of UI element
public enum ElementType: String, Sendable, Codable {
    case button
    case textField
    case link
    case image
    case group
    case slider
    case checkbox
    case menu
    case other
    case staticText
    case radioButton
    case menuItem
    case window
    case dialog
}

// MARK: - Click Types

/// Type of click operation
public enum ClickType: String, Sendable, Codable {
    case single
    case right
    case double
    case longPress
}

// MARK: - Scroll & Swipe

/// Direction for scroll operations
public enum ScrollDirection: String, Sendable, Codable {
    case up
    case down
    case left
    case right
}

/// Direction for swipe operations
public enum SwipeDirection: String, Sendable {
    case up
    case down
    case left
    case right
}

// MARK: - Dialog Interactions

/// Elements that appear in dialog interactions
public enum DialogElementType: String, Sendable, Codable {
    case button
    case textField
    case checkbox
    case radioButton
    case dropdown
    case alert
    case other
}

/// Actions performed during dialog interactions
public enum DialogActionType: String, Sendable, Codable {
    case clickButton = "click_button"
    case enterText = "enter_text"
    case handleFileDialog = "handle_file_dialog"
    case dismiss
    case toggle
    case select
}

// MARK: - Keyboard

/// Modifier keys for keyboard operations
public enum ModifierKey: String, Sendable {
    case command = "cmd"
    case control = "ctrl"
    case option = "alt"
    case shift
    case function = "fn"
}

/// Special keys for typing operations
public enum SpecialKey: String, Sendable, Codable {
    case `return`
    case enter // Numeric keypad enter
    case tab
    case escape
    case delete // Backspace
    case forwardDelete = "forward_delete" // fn+delete
    case space
    case leftArrow = "left"
    case rightArrow = "right"
    case upArrow = "up"
    case downArrow = "down"
    case pageUp = "pageup"
    case pageDown = "pagedown"
    case home
    case end
    case f1
    case f2
    case f3
    case f4
    case f5
    case f6
    case f7
    case f8
    case f9
    case f10
    case f11
    case f12
    case capsLock = "caps_lock"
    case clear
    case help
}

// MARK: - Type Actions

/// Actions for typing operations
public enum TypeAction: Sendable, Codable {
    case text(String)
    case key(SpecialKey)
    case clear

    private enum CodingKeys: String, CodingKey { case kind, text, key }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "text":
            let value = try container.decode(String.self, forKey: .text)
            self = .text(value)
        case "key":
            let value = try container.decode(SpecialKey.self, forKey: .key)
            self = .key(value)
        case "clear":
            self = .clear
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown TypeAction kind: \(kind)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(value):
            try container.encode("text", forKey: .kind)
            try container.encode(value, forKey: .text)
        case let .key(key):
            try container.encode("key", forKey: .kind)
            try container.encode(key, forKey: .key)
        case .clear:
            try container.encode("clear", forKey: .kind)
        }
    }
}

/// Typing profile exposed to higher-level tooling/visualizers
public enum TypingProfile: String, Sendable, Codable {
    case human
    case linear
}

/// Typing cadence configuration for automation services
public enum TypingCadence: Sendable, Equatable {
    case fixed(milliseconds: Int)
    case human(wordsPerMinute: Int)

    public var profile: TypingProfile {
        switch self {
        case .fixed:
            .linear
        case .human:
            .human
        }
    }
}

extension TypingCadence: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case milliseconds
        case wordsPerMinute
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "fixed":
            let value = try container.decode(Int.self, forKey: .milliseconds)
            self = .fixed(milliseconds: value)
        case "human":
            let wpm = try container.decode(Int.self, forKey: .wordsPerMinute)
            self = .human(wordsPerMinute: wpm)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown typing cadence kind \(kind)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .fixed(milliseconds):
            try container.encode("fixed", forKey: .kind)
            try container.encode(milliseconds, forKey: .milliseconds)
        case let .human(wordsPerMinute):
            try container.encode("human", forKey: .kind)
            try container.encode(wordsPerMinute, forKey: .wordsPerMinute)
        }
    }
}

// MARK: - CustomStringConvertible Conformances

extension ClickType: CustomStringConvertible {
    public var description: String {
        switch self {
        case .single: "single"
        case .right: "right"
        case .double: "double"
        case .longPress: "long press"
        }
    }
}

extension ScrollDirection: CustomStringConvertible {
    public var description: String {
        switch self {
        case .up: "up"
        case .down: "down"
        case .left: "left"
        case .right: "right"
        }
    }
}
