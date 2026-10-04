import Foundation

/// Per-app overrides for action/synthesis strategy selection.
public struct AppUIInputPolicy: Codable, Equatable, Sendable {
    public var defaultStrategy: UIInputStrategy?
    public var click: UIInputStrategy?
    public var scroll: UIInputStrategy?
    public var type: UIInputStrategy?
    public var hotkey: UIInputStrategy?
    public var setValue: UIInputStrategy?
    public var performAction: UIInputStrategy?

    public init(
        defaultStrategy: UIInputStrategy? = nil,
        click: UIInputStrategy? = nil,
        scroll: UIInputStrategy? = nil,
        type: UIInputStrategy? = nil,
        hotkey: UIInputStrategy? = nil,
        setValue: UIInputStrategy? = nil,
        performAction: UIInputStrategy? = nil)
    {
        self.defaultStrategy = defaultStrategy
        self.click = click
        self.scroll = scroll
        self.type = type
        self.hotkey = hotkey
        self.setValue = setValue
        self.performAction = performAction
    }

    public func strategy(for verb: UIInputVerb) -> UIInputStrategy? {
        switch verb {
        case .click:
            self.click ?? self.defaultStrategy
        case .scroll:
            self.scroll ?? self.defaultStrategy
        case .type:
            self.type ?? self.defaultStrategy
        case .hotkey:
            self.hotkey ?? self.defaultStrategy
        case .setValue:
            self.setValue ?? self.defaultStrategy
        case .selectText:
            .actionOnly
        case .performAction:
            self.performAction ?? self.defaultStrategy
        }
    }
}

/// Resolved input policy for action/synthesis dispatch.
public struct UIInputPolicy: Codable, Equatable, Sendable {
    public static let currentBehavior = UIInputPolicy.applicationDefaults(resolving: AppUIInputPolicy(
        click: .actionFirst,
        scroll: .actionFirst,
        setValue: .actionOnly,
        performAction: .actionOnly))

    public var defaultStrategy: UIInputStrategy {
        didSet {
            self.backgroundTypingDefault = nil
            self.backgroundSelectAllDefault = nil
        }
    }

    public var click: UIInputStrategy?
    public var scroll: UIInputStrategy?
    public var type: UIInputStrategy?
    public var hotkey: UIInputStrategy?
    public var setValue: UIInputStrategy?
    public var performAction: UIInputStrategy?
    public var perApp: [String: AppUIInputPolicy]
    /// Applies only to targeted typing when no explicit type or per-app selection wins.
    public private(set) var backgroundTypingDefault: UIInputStrategy?
    /// Prefers focused text selection only, not app-wide menus, for targeted Cmd+A without an explicit selection.
    public private(set) var backgroundSelectAllDefault: UIInputStrategy?

    public init(
        defaultStrategy: UIInputStrategy = .synthFirst,
        click: UIInputStrategy? = nil,
        scroll: UIInputStrategy? = nil,
        type: UIInputStrategy? = nil,
        hotkey: UIInputStrategy? = nil,
        setValue: UIInputStrategy? = nil,
        performAction: UIInputStrategy? = nil,
        perApp: [String: AppUIInputPolicy] = [:])
    {
        self.defaultStrategy = defaultStrategy
        self.click = click
        self.scroll = scroll
        self.type = type
        self.hotkey = hotkey
        self.setValue = setValue
        self.performAction = performAction
        self.perApp = perApp
        self.backgroundTypingDefault = nil
        self.backgroundSelectAllDefault = nil
    }

    /// Keep resolved selections authoritative while preserving the absence of a global override.
    public static func applicationDefaults(
        resolving selections: AppUIInputPolicy,
        perApp: [String: AppUIInputPolicy] = [:]) -> Self
    {
        var policy = Self(
            defaultStrategy: selections.defaultStrategy ?? .synthFirst,
            click: selections.click,
            scroll: selections.scroll,
            type: selections.type,
            hotkey: selections.hotkey,
            setValue: selections.setValue,
            performAction: selections.performAction,
            perApp: perApp)
        if selections.defaultStrategy == nil {
            policy.backgroundTypingDefault = .actionFirst
            policy.backgroundSelectAllDefault = .actionFirst
        }
        return policy
    }

    public func backgroundTypingStrategy(bundleIdentifier: String? = nil) -> UIInputStrategy {
        self.appStrategy(for: .type, bundleIdentifier: bundleIdentifier) ?? self.type ??
            self.backgroundTypingDefault ?? self.defaultStrategy
    }

    public func backgroundSelectAllStrategy(bundleIdentifier: String? = nil) -> UIInputStrategy {
        self.resolvedBackgroundHotkeyStrategy(isSelectAll: true, bundleIdentifier: bundleIdentifier).strategy
    }

    struct BackgroundHotkeyStrategy: Sendable {
        let strategy: UIInputStrategy
        let usesBuiltInPreference: Bool
    }

    func resolvedBackgroundHotkeyStrategy(
        isSelectAll: Bool,
        bundleIdentifier: String? = nil) -> BackgroundHotkeyStrategy
    {
        if let explicit = self.appStrategy(for: .hotkey, bundleIdentifier: bundleIdentifier) ?? self.hotkey {
            return .init(strategy: explicit, usesBuiltInPreference: false)
        }
        if isSelectAll, let backgroundSelectAllDefault {
            return .init(strategy: backgroundSelectAllDefault, usesBuiltInPreference: true)
        }
        return .init(strategy: self.defaultStrategy, usesBuiltInPreference: false)
    }

    public func strategy(for verb: UIInputVerb, bundleIdentifier: String? = nil) -> UIInputStrategy {
        if let appStrategy = self.appStrategy(for: verb, bundleIdentifier: bundleIdentifier) {
            return appStrategy
        }

        switch verb {
        case .click:
            return self.click ?? self.defaultStrategy
        case .scroll:
            return self.scroll ?? self.defaultStrategy
        case .type:
            return self.type ?? self.defaultStrategy
        case .hotkey:
            return self.hotkey ?? self.defaultStrategy
        case .setValue:
            return self.setValue ?? self.defaultStrategy
        case .selectText:
            return .actionOnly
        case .performAction:
            return self.performAction ?? self.defaultStrategy
        }
    }

    private func appStrategy(for verb: UIInputVerb, bundleIdentifier: String?) -> UIInputStrategy? {
        bundleIdentifier.flatMap { self.perApp[$0]?.strategy(for: verb) }
    }
}
