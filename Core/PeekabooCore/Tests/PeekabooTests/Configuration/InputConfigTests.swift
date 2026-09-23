import Darwin
import Foundation
import PeekabooAutomationKit
import Testing
@testable import PeekabooAutomation

@Suite(.serialized)
struct InputConfigTests {
    @Test
    func `Codable round-trip for input strategy config`() throws {
        let input = Configuration.InputConfig(
            defaultStrategy: .synthFirst,
            click: .actionFirst,
            scroll: .actionOnly,
            perApp: [
                "com.example.Terminal": Configuration.AppInputConfig(
                    hotkey: .synthOnly,
                    setValue: .actionFirst),
            ])
        let config = Configuration(input: input)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Configuration.self, from: data)

        #expect(decoded.input?.defaultStrategy == .synthFirst)
        #expect(decoded.input?.click == .actionFirst)
        #expect(decoded.input?.scroll == .actionOnly)
        #expect(decoded.input?.perApp?["com.example.Terminal"]?.hotkey == .synthOnly)
        #expect(decoded.input?.perApp?["com.example.Terminal"]?.setValue == .actionFirst)
    }

    @Test
    func `UI input policy defaults click scroll and type to action-first`() throws {
        try withIsolatedInputPolicyEnvironment(configJSON: nil) {
            let policy = ConfigurationManager.shared.getUIInputPolicy()

            #expect(policy == .currentBehavior)
            #expect(policy.defaultStrategy == .synthFirst)
            #expect(policy.strategy(for: .click) == .actionFirst)
            #expect(policy.strategy(for: .scroll) == .actionFirst)
            #expect(policy.strategy(for: .type) == .actionFirst)
            #expect(policy.strategy(for: .hotkey) == .synthFirst)
            #expect(policy.strategy(for: .setValue) == .actionOnly)
            #expect(policy.strategy(for: .performAction) == .actionOnly)
        }
    }

    @Test
    func `UI input policy resolves config verb and per-app overrides`() throws {
        let configJSON = """
        {
          "input": {
            "defaultStrategy": "synthFirst",
            "click": "actionFirst",
            "scroll": "actionOnly",
            "perApp": {
              "com.example.Editor": {
                "defaultStrategy": "synthOnly",
                "hotkey": "actionFirst"
              }
            }
          }
        }
        """

        try withIsolatedInputPolicyEnvironment(configJSON: configJSON) {
            let policy = ConfigurationManager.shared.getUIInputPolicy()

            #expect(policy.strategy(for: .click) == .actionFirst)
            #expect(policy.strategy(for: .scroll) == .actionOnly)
            #expect(policy.strategy(for: .type) == .synthFirst)
            #expect(policy.strategy(for: .click, bundleIdentifier: "com.example.Editor") == .synthOnly)
            #expect(policy.strategy(for: .hotkey, bundleIdentifier: "com.example.Editor") == .actionFirst)
        }
    }

    @Test(arguments: [UIInputStrategy.synthFirst, .synthOnly])
    func `configured default strategy overrides built-in action-first defaults`(strategy: UIInputStrategy) throws {
        let configJSON = """
        {
          "input": {
            "defaultStrategy": "\(strategy.rawValue)"
          }
        }
        """

        try withIsolatedInputPolicyEnvironment(configJSON: configJSON) {
            let policy = ConfigurationManager.shared.getUIInputPolicy()

            #expect(policy.defaultStrategy == strategy)
            #expect(policy.strategy(for: .click) == strategy)
            #expect(policy.strategy(for: .scroll) == strategy)
            #expect(policy.strategy(for: .type) == strategy)
            #expect(policy.strategy(for: .hotkey) == strategy)
            #expect(policy.strategy(for: .setValue) == .actionOnly)
            #expect(policy.strategy(for: .performAction) == .actionOnly)
        }
    }

    @Test
    func `explicit synth-first type config overrides the built-in default`() throws {
        let configJSON = """
        {
          "input": {
            "type": "synthFirst"
          }
        }
        """

        try withIsolatedInputPolicyEnvironment(configJSON: configJSON) {
            let policy = ConfigurationManager.shared.getUIInputPolicy()

            #expect(policy.strategy(for: .type) == .synthFirst)
            #expect(policy.strategy(for: .click) == .actionFirst)
        }
    }

    @Test(arguments: ["defaultStrategy", "type"])
    func `explicit per-app synth-first type overrides the built-in default`(key: String) throws {
        let configJSON = """
        {
          "input": {
            "perApp": {
              "com.example.Editor": {
                "\(key)": "synthFirst"
              }
            }
          }
        }
        """

        try withIsolatedInputPolicyEnvironment(configJSON: configJSON) {
            let policy = ConfigurationManager.shared.getUIInputPolicy()

            #expect(policy.strategy(for: .type) == .actionFirst)
            #expect(policy.strategy(for: .type, bundleIdentifier: "com.example.Editor") == .synthFirst)
            #expect(policy.strategy(for: .type, bundleIdentifier: "com.example.Other") == .actionFirst)
        }
    }

    @Test(arguments: ["PEEKABOO_INPUT_STRATEGY", "PEEKABOO_TYPE_INPUT_STRATEGY"])
    func `explicit synth-first environment overrides type and per-app config`(key: String) throws {
        let configJSON = """
        {
          "input": {
            "defaultStrategy": "actionOnly",
            "type": "actionOnly",
            "perApp": {
              "com.example.Editor": {
                "defaultStrategy": "actionOnly",
                "type": "actionOnly"
              }
            }
          }
        }
        """
        var environment = ["PEEKABOO_INPUT_STRATEGY": "actionOnly"]
        environment[key] = "synthFirst"

        try withIsolatedInputPolicyEnvironment(configJSON: configJSON, environment: environment) {
            let policy = ConfigurationManager.shared.getUIInputPolicy()
            let expectedHotkey: UIInputStrategy = key == "PEEKABOO_INPUT_STRATEGY" ? .synthFirst : .actionOnly

            #expect(policy.strategy(for: .type) == .synthFirst)
            #expect(policy.strategy(for: .type, bundleIdentifier: "com.example.Editor") == .synthFirst)
            #expect(policy.strategy(for: .hotkey) == expectedHotkey)
            #expect(policy.strategy(for: .hotkey, bundleIdentifier: "com.example.Editor") == expectedHotkey)
        }
    }

    @Test
    func `explicit CLI synth-first overrides type environment and per-app config`() throws {
        let configJSON = """
        {
          "input": {
            "type": "actionOnly",
            "perApp": {
              "com.example.Editor": {
                "defaultStrategy": "actionOnly",
                "type": "actionOnly"
              }
            }
          }
        }
        """

        try withIsolatedInputPolicyEnvironment(
            configJSON: configJSON,
            environment: [
                "PEEKABOO_INPUT_STRATEGY": "actionOnly",
                "PEEKABOO_TYPE_INPUT_STRATEGY": "actionOnly",
            ]) {
                let policy = ConfigurationManager.shared.getUIInputPolicy(cliStrategy: .synthFirst)

                #expect(policy.defaultStrategy == .synthFirst)
                #expect(policy.strategy(for: .type) == .synthFirst)
                #expect(policy.strategy(for: .type, bundleIdentifier: "com.example.Editor") == .synthFirst)
            }
    }

    @Test
    func `UI input policy resolves CLI before env before config`() throws {
        let configJSON = """
        {
          "input": {
            "defaultStrategy": "synthFirst",
            "click": "synthOnly",
            "perApp": {
              "com.example.Editor": {
                "defaultStrategy": "actionFirst"
              }
            }
          }
        }
        """

        try withIsolatedInputPolicyEnvironment(
            configJSON: configJSON,
            environment: ["PEEKABOO_INPUT_STRATEGY": "actionFirst"])
        {
            let policy = ConfigurationManager.shared.getUIInputPolicy(cliStrategy: .actionOnly)

            #expect(policy.defaultStrategy == .actionOnly)
            #expect(policy.strategy(for: .click) == .actionOnly)
            #expect(policy.strategy(for: .scroll) == .actionOnly)
            #expect(policy.strategy(for: .click, bundleIdentifier: "com.example.Editor") == .actionOnly)
            #expect(policy.strategy(for: .type, bundleIdentifier: "com.example.Editor") == .actionOnly)
        }
    }

    @Test
    func `UI input policy resolves global env before per-app config`() throws {
        let configJSON = """
        {
          "input": {
            "defaultStrategy": "synthFirst",
            "perApp": {
              "com.example.Editor": {
                "defaultStrategy": "actionFirst"
              }
            }
          }
        }
        """

        try withIsolatedInputPolicyEnvironment(
            configJSON: configJSON,
            environment: ["PEEKABOO_INPUT_STRATEGY": "synthOnly"])
        {
            let policy = ConfigurationManager.shared.getUIInputPolicy()

            #expect(policy.strategy(for: .click, bundleIdentifier: "com.example.Editor") == .synthOnly)
            #expect(policy.strategy(for: .hotkey, bundleIdentifier: "com.example.Editor") == .synthOnly)
        }
    }

    @Test
    func `UI input policy resolves verb env before per-app config for that verb only`() throws {
        let configJSON = """
        {
          "input": {
            "defaultStrategy": "synthFirst",
            "perApp": {
              "com.example.Editor": {
                "defaultStrategy": "actionFirst"
              }
            }
          }
        }
        """

        try withIsolatedInputPolicyEnvironment(
            configJSON: configJSON,
            environment: ["PEEKABOO_CLICK_INPUT_STRATEGY": "synthOnly"])
        {
            let policy = ConfigurationManager.shared.getUIInputPolicy()

            #expect(policy.strategy(for: .click, bundleIdentifier: "com.example.Editor") == .synthOnly)
            #expect(policy.strategy(for: .hotkey, bundleIdentifier: "com.example.Editor") == .actionFirst)
        }
    }

    @Test
    func `UI input policy resolves specific env before global env`() throws {
        try withIsolatedInputPolicyEnvironment(
            configJSON: nil,
            environment: [
                "PEEKABOO_INPUT_STRATEGY": "actionFirst",
                "PEEKABOO_HOTKEY_INPUT_STRATEGY": "synthOnly",
            ]) {
                let policy = ConfigurationManager.shared.getUIInputPolicy()

                #expect(policy.strategy(for: .click) == .actionFirst)
                #expect(policy.strategy(for: .hotkey) == .synthOnly)
            }
    }

    @Test
    func `UI input policy ignores invalid env strategy values`() throws {
        let configJSON = """
        {
          "input": {
            "click": "actionFirst"
          }
        }
        """

        try withIsolatedInputPolicyEnvironment(
            configJSON: configJSON,
            environment: ["PEEKABOO_CLICK_INPUT_STRATEGY": "not-a-strategy"])
        {
            let policy = ConfigurationManager.shared.getUIInputPolicy()

            #expect(policy.strategy(for: .click) == .actionFirst)
        }
    }
}

private func withIsolatedInputPolicyEnvironment(
    configJSON: String?,
    environment: [String: String] = [:],
    _ body: () throws -> Void) throws
{
    let fileManager = FileManager.default
    let configDir = fileManager.temporaryDirectory
        .appendingPathComponent("peekaboo-input-config-tests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)

    let managedKeys = [
        "PEEKABOO_CONFIG_DIR",
        "PEEKABOO_CONFIG_DISABLE_MIGRATION",
        "PEEKABOO_INPUT_STRATEGY",
        "PEEKABOO_CLICK_INPUT_STRATEGY",
        "PEEKABOO_SCROLL_INPUT_STRATEGY",
        "PEEKABOO_TYPE_INPUT_STRATEGY",
        "PEEKABOO_HOTKEY_INPUT_STRATEGY",
        "PEEKABOO_SET_VALUE_INPUT_STRATEGY",
        "PEEKABOO_PERFORM_ACTION_INPUT_STRATEGY",
    ]
    let previousValues = Dictionary(uniqueKeysWithValues: managedKeys.map { key in
        (key, getenv(key).map { String(cString: $0) })
    })

    defer {
        for (key, value) in previousValues {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
        ConfigurationManager.shared.resetForTesting()
        try? fileManager.removeItem(at: configDir)
    }

    for key in managedKeys {
        unsetenv(key)
    }
    setenv("PEEKABOO_CONFIG_DIR", configDir.path, 1)
    setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", "1", 1)
    for (key, value) in environment {
        setenv(key, value, 1)
    }

    if let configJSON {
        let configPath = configDir.appendingPathComponent("config.json")
        try configJSON.write(to: configPath, atomically: true, encoding: .utf8)
    }

    ConfigurationManager.shared.resetForTesting()
    _ = ConfigurationManager.shared.loadConfiguration()

    try body()
}
