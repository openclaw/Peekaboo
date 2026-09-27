import Foundation
import Testing
@testable import PeekabooAutomationKit

struct UIInputPolicyDefaultTests {
    @Test
    func `ordinary construction preserves its concrete synth first policy`() {
        let policy = UIInputPolicy()

        #expect(policy == UIInputPolicy(defaultStrategy: .synthFirst))
        #expect(policy.backgroundTypingDefault == nil)
        #expect(policy.backgroundSelectAllDefault == nil)
        #expect(policy.backgroundSelectAllStrategy() == .synthFirst)
        #expect(policy.backgroundTypingStrategy() == .synthFirst)
        for verb in UIInputVerb.allCases {
            #expect(policy.strategy(for: verb) == .synthFirst)
        }
    }

    @Test
    func `current behavior separates legacy and background typing defaults`() {
        let policy = UIInputPolicy.currentBehavior

        #expect(policy.defaultStrategy == .synthFirst)
        #expect(policy.type == nil)
        #expect(policy.backgroundTypingDefault == .actionFirst)
        #expect(policy.backgroundSelectAllDefault == .actionFirst)
        #expect(policy.backgroundSelectAllStrategy() == .actionFirst)
        #expect(policy.strategy(for: .type) == .synthFirst)
        #expect(policy.backgroundTypingStrategy() == .actionFirst)
        #expect(policy.strategy(for: .click) == .actionFirst)
        #expect(policy.strategy(for: .scroll) == .actionFirst)
        #expect(policy.strategy(for: .hotkey) == .synthFirst)
        #expect(policy.strategy(for: .setValue) == .actionOnly)
        #expect(policy.strategy(for: .performAction) == .actionOnly)
        #expect(policy == UIInputPolicy.applicationDefaults(resolving: AppUIInputPolicy(
            click: .actionFirst,
            scroll: .actionFirst,
            setValue: .actionOnly,
            performAction: .actionOnly)))
    }

    @Test(arguments: UIInputStrategy.allCases)
    func `explicit global selections suppress the background default even at builtin values`(
        strategy: UIInputStrategy)
    {
        let constructed = UIInputPolicy(defaultStrategy: strategy)
        let resolved = UIInputPolicy.applicationDefaults(resolving: AppUIInputPolicy(defaultStrategy: strategy))

        #expect(constructed == resolved)
        for policy in [constructed, resolved] {
            #expect(policy.backgroundTypingDefault == nil)
            #expect(policy.strategy(for: .type) == strategy)
            #expect(policy.backgroundTypingStrategy() == strategy)
        }
    }

    @Test(arguments: UIInputStrategy.allCases, [false, true])
    func `explicit type selections win with or without an explicit global selection`(
        strategy: UIInputStrategy,
        hasGlobalSelection: Bool)
    {
        let policy = UIInputPolicy.applicationDefaults(resolving: AppUIInputPolicy(
            defaultStrategy: hasGlobalSelection ? .synthOnly : nil,
            type: strategy))

        #expect(policy.type == strategy)
        #expect(policy.backgroundTypingDefault == (hasGlobalSelection ? nil : .actionFirst))
        #expect(policy.strategy(for: .type) == strategy)
        #expect(policy.backgroundTypingStrategy() == strategy)
    }

    @Test(arguments: UIInputStrategy.allCases, [false, true])
    func `per app type and global selections beat the top level type selection`(
        strategy: UIInputStrategy,
        usesAppDefault: Bool)
    {
        let appPolicy = usesAppDefault
            ? AppUIInputPolicy(defaultStrategy: strategy)
            : AppUIInputPolicy(defaultStrategy: .synthOnly, type: strategy)
        let policy = UIInputPolicy.applicationDefaults(
            resolving: AppUIInputPolicy(type: .actionOnly),
            perApp: ["com.example.editor": appPolicy])

        #expect(policy.strategy(for: .type, bundleIdentifier: "com.example.editor") == strategy)
        #expect(policy.backgroundTypingStrategy(bundleIdentifier: "com.example.editor") == strategy)
        #expect(policy.strategy(for: .type, bundleIdentifier: "com.example.other") == .actionOnly)
        #expect(policy.backgroundTypingStrategy(bundleIdentifier: "com.example.other") == .actionOnly)
    }

    @Test
    func `unrelated per app selections do not override either typing default`() {
        let policy = UIInputPolicy.applicationDefaults(
            resolving: AppUIInputPolicy(),
            perApp: ["com.example.editor": AppUIInputPolicy(click: .actionOnly)])

        #expect(policy.strategy(for: .type, bundleIdentifier: "com.example.editor") == .synthFirst)
        #expect(policy.backgroundTypingStrategy(bundleIdentifier: "com.example.editor") == .actionFirst)
    }

    @Test
    func `assigning the same global value clears the background fallback`() {
        var policy = UIInputPolicy.currentBehavior

        policy.defaultStrategy = .synthFirst

        #expect(policy.backgroundTypingDefault == nil)
        #expect(policy.strategy(for: .type) == .synthFirst)
        #expect(policy.backgroundSelectAllDefault == nil)
        #expect(policy.backgroundSelectAllStrategy() == .synthFirst)
        #expect(policy.backgroundTypingStrategy() == .synthFirst)
        #expect(policy != .currentBehavior)
    }

    @Test(arguments: UIInputStrategy.allCases)
    func `clearing an explicit type selection restores only the named background default`(
        strategy: UIInputStrategy)
    {
        var policy = UIInputPolicy.currentBehavior
        policy.type = strategy

        #expect(policy.backgroundTypingDefault == .actionFirst)
        #expect(policy.strategy(for: .type) == strategy)
        #expect(policy.backgroundTypingStrategy() == strategy)

        policy.type = nil

        #expect(policy == .currentBehavior)
        #expect(policy.strategy(for: .type) == .synthFirst)
        #expect(policy.backgroundTypingStrategy() == .actionFirst)
    }

    @Test
    func `global reassignment does not erase an explicit type selection`() {
        var policy = UIInputPolicy.currentBehavior
        policy.type = .actionFirst
        policy.defaultStrategy = .synthFirst

        #expect(policy.backgroundTypingDefault == nil)
        #expect(policy.type == .actionFirst)
        #expect(policy.strategy(for: .type) == .actionFirst)
        #expect(policy.backgroundTypingStrategy() == .actionFirst)

        policy.type = nil

        #expect(policy.strategy(for: .type) == .synthFirst)
        #expect(policy.backgroundTypingStrategy() == .synthFirst)
    }

    @Test(arguments: [false, true])
    func `application defaults retain the named fallback through Codable`(usesCurrentBehavior: Bool) throws {
        let policy = usesCurrentBehavior
            ? UIInputPolicy.currentBehavior
            : UIInputPolicy.applicationDefaults(resolving: AppUIInputPolicy())
        let encoded = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(UIInputPolicy.self, from: encoded)

        #expect(decoded == policy)
        #expect(decoded.backgroundTypingDefault == .actionFirst)
        #expect(decoded.strategy(for: .type) == .synthFirst)
        #expect(decoded.backgroundTypingStrategy() == .actionFirst)
    }

    @Test
    func `equality includes the fallback even when legacy fields match`() {
        var defaults = UIInputPolicy.applicationDefaults(resolving: AppUIInputPolicy())
        let concrete = UIInputPolicy()

        #expect(defaults.defaultStrategy == concrete.defaultStrategy)
        #expect(defaults.type == concrete.type)
        #expect(defaults.strategy(for: .type) == concrete.strategy(for: .type))
        #expect(defaults != concrete)

        defaults.defaultStrategy = .synthFirst

        #expect(defaults == concrete)
    }

    @Test(arguments: UIInputStrategy.allCases, [false, true])
    func `old resolved JSON remains authoritative on both typing surfaces`(
        strategy: UIInputStrategy,
        usesTypeSelection: Bool) throws
    {
        let json = usesTypeSelection
            ? """
            {"defaultStrategy":"synthFirst","type":"\(strategy.rawValue)","perApp":{}}
            """
            : """
            {"defaultStrategy":"\(strategy.rawValue)","perApp":{}}
            """
        let policy = try JSONDecoder().decode(UIInputPolicy.self, from: Data(json.utf8))

        #expect(policy.backgroundTypingDefault == nil)
        #expect(policy.strategy(for: .type) == strategy)
        #expect(policy.backgroundTypingStrategy() == strategy)
        #expect(try JSONDecoder().decode(UIInputPolicy.self, from: JSONEncoder().encode(policy)) == policy)
    }

    @Test
    func `a null background fallback retains the old concrete global behavior`() throws {
        let json = """
        {"defaultStrategy":"synthFirst","perApp":{},"backgroundTypingDefault":null}
        """
        let policy = try JSONDecoder().decode(UIInputPolicy.self, from: Data(json.utf8))

        #expect(policy == UIInputPolicy())
        #expect(policy.backgroundTypingDefault == nil)
        #expect(policy.backgroundTypingStrategy() == .synthFirst)
    }

    @Test(arguments: UIInputStrategy.allCases)
    func `the named JSON fallback changes only background typing`(strategy: UIInputStrategy) throws {
        let json = """
        {"defaultStrategy":"synthOnly","perApp":{},"backgroundTypingDefault":"\(strategy.rawValue)"}
        """
        let policy = try JSONDecoder().decode(UIInputPolicy.self, from: Data(json.utf8))

        #expect(policy.backgroundTypingDefault == strategy)
        #expect(policy.strategy(for: .type) == .synthOnly)
        #expect(policy.backgroundTypingStrategy() == strategy)
        #expect(try JSONDecoder().decode(UIInputPolicy.self, from: JSONEncoder().encode(policy)) == policy)
    }

    @Test(arguments: UIInputStrategy.allCases, ["global", "hotkey", "appGlobal", "appHotkey"])
    func `select all retains the explicit winning field rather than guessing from its value`(
        strategy: UIInputStrategy, source: String)
    {
        let bundle = "com.example.editor"
        var policy = UIInputPolicy.currentBehavior
        switch source {
        case "global": policy.defaultStrategy = strategy
        case "hotkey": policy.hotkey = strategy
        case "appGlobal": policy.perApp[bundle] = AppUIInputPolicy(defaultStrategy: strategy)
        default: policy.perApp[bundle] = AppUIInputPolicy(defaultStrategy: .synthOnly, hotkey: strategy)
        }

        let resolution = policy.resolvedBackgroundHotkeyStrategy(isSelectAll: true, bundleIdentifier: bundle)

        #expect(resolution.strategy == strategy)
        #expect(!resolution.usesBuiltInPreference)
        #expect(policy.backgroundSelectAllStrategy(bundleIdentifier: bundle) == strategy)
    }

    @Test
    func `select all default is limited to focused selection and independent from typing`() {
        var policy = UIInputPolicy.currentBehavior
        policy.type = .synthOnly
        policy.perApp["com.example.editor"] = AppUIInputPolicy(type: .actionOnly)

        let selected = policy.resolvedBackgroundHotkeyStrategy(
            isSelectAll: true, bundleIdentifier: "com.example.editor")
        let ordinary = policy.resolvedBackgroundHotkeyStrategy(
            isSelectAll: false, bundleIdentifier: "com.example.editor")

        #expect(selected.strategy == .actionFirst)
        #expect(selected.usesBuiltInPreference)
        #expect(ordinary.strategy == .synthFirst)
        #expect(!ordinary.usesBuiltInPreference)
        #expect(policy.backgroundTypingStrategy(bundleIdentifier: "com.example.editor") == .actionOnly)
    }

    @Test
    func `clearing a hotkey override restores only the named selection preference`() {
        var policy = UIInputPolicy.currentBehavior
        policy.hotkey = .actionFirst
        #expect(!policy.resolvedBackgroundHotkeyStrategy(isSelectAll: true).usesBuiltInPreference)

        policy.hotkey = nil
        #expect(policy.resolvedBackgroundHotkeyStrategy(isSelectAll: true).usesBuiltInPreference)
        #expect(policy.backgroundSelectAllStrategy() == .actionFirst)
        #expect(policy.strategy(for: .hotkey) == .synthFirst)

        policy.defaultStrategy = .synthFirst
        #expect(policy.backgroundSelectAllDefault == nil)
        #expect(!policy.resolvedBackgroundHotkeyStrategy(isSelectAll: true).usesBuiltInPreference)
        #expect(policy.backgroundSelectAllStrategy() == .synthFirst)
    }

    @Test
    func `selection preference round trips while old policy JSON stays concrete`() throws {
        let current = UIInputPolicy.currentBehavior
        let roundTrip = try JSONDecoder().decode(UIInputPolicy.self, from: JSONEncoder().encode(current))
        #expect(roundTrip == current)
        #expect(roundTrip.backgroundSelectAllDefault == .actionFirst)
        #expect(roundTrip.resolvedBackgroundHotkeyStrategy(isSelectAll: true).usesBuiltInPreference)

        for json in [
            #"{"defaultStrategy":"synthFirst","perApp":{}}"#,
            #"{"defaultStrategy":"synthFirst","perApp":{},"backgroundSelectAllDefault":null}"#,
            #"{"defaultStrategy":"synthFirst","perApp":{},"backgroundTypingDefault":"actionFirst"}"#,
        ] {
            let decoded = try JSONDecoder().decode(UIInputPolicy.self, from: Data(json.utf8))
            #expect(decoded.backgroundSelectAllDefault == nil)
            #expect(decoded.backgroundSelectAllStrategy() == .synthFirst)
            #expect(!decoded.resolvedBackgroundHotkeyStrategy(isSelectAll: true).usesBuiltInPreference)
        }
    }

    @Test(arguments: UIInputStrategy.allCases)
    func `a named serialized selection preference changes only targeted select all`(strategy: UIInputStrategy) throws {
        let json = """
        {"defaultStrategy":"synthOnly","perApp":{},"backgroundSelectAllDefault":"\(strategy.rawValue)"}
        """
        let policy = try JSONDecoder().decode(UIInputPolicy.self, from: Data(json.utf8))

        #expect(policy.backgroundSelectAllStrategy() == strategy)
        #expect(policy.resolvedBackgroundHotkeyStrategy(isSelectAll: true).usesBuiltInPreference)
        #expect(policy.strategy(for: .hotkey) == .synthOnly)
        #expect(policy.backgroundTypingStrategy() == .synthOnly)
    }

    @Test(arguments: ["defaultStrategy", "perApp"])
    func `old nonoptional JSON keys remain required`(missingKey: String) throws {
        let json = missingKey == "defaultStrategy"
            ? #"{"perApp":{}}"#
            : #"{"defaultStrategy":"synthFirst"}"#

        do {
            _ = try JSONDecoder().decode(UIInputPolicy.self, from: Data(json.utf8))
            Issue.record("Expected a missing required key: \(missingKey)")
        } catch let DecodingError.keyNotFound(key, _) {
            #expect(key.stringValue == missingKey)
        }
    }
}
