import Foundation
import Testing
@testable import Peekaboo

@MainActor
final class TestCredentialStore: CredentialStore {
    enum Failure: Error {
        case requested
    }

    var values: [PeekabooCredential: String]
    var readFailures: Set<PeekabooCredential> = []
    var writeFailures: Set<PeekabooCredential> = []
    var removeFailures: Set<PeekabooCredential> = []

    init(
        values: [PeekabooCredential: String] = [:],
        blocksPersistence: Bool = false)
    {
        self.values = values
        if blocksPersistence {
            self.writeFailures = Set(PeekabooCredential.allCases)
            self.removeFailures = Set(PeekabooCredential.allCases)
        }
    }

    func value(for credential: PeekabooCredential) throws -> String? {
        if self.readFailures.contains(credential) {
            throw Failure.requested
        }
        return self.values[credential]
    }

    func setValue(_ value: String, for credential: PeekabooCredential) throws {
        if self.writeFailures.contains(credential) {
            throw Failure.requested
        }
        self.values[credential] = value
    }

    func removeValue(for credential: PeekabooCredential) throws {
        if self.removeFailures.contains(credential) {
            throw Failure.requested
        }
        self.values.removeValue(forKey: credential)
    }
}

@MainActor
func makeTestSettings(
    credentialStore: TestCredentialStore = TestCredentialStore(blocksPersistence: true)) -> PeekabooSettings
{
    PeekabooSettings(credentialStore: credentialStore)
}

@Suite(.tags(.services, .unit), .serialized)
@MainActor
struct PeekabooCredentialStoreTests {
    @Test(arguments: PeekabooCredential.allCases)
    func `Legacy credentials migrate per provider`(_ credential: PeekabooCredential) throws {
        try withIsolatedSettingsEnvironment { _, credentialStore in
            let legacyValue = "legacy-\(credential.rawValue)"
            let legacyKey = "peekaboo.\(credential.rawValue)"
            UserDefaults.standard.set(legacyValue, forKey: legacyKey)

            let settings = PeekabooSettings(credentialStore: credentialStore)

            #expect(self.value(for: credential, in: settings) == legacyValue)
            #expect(credentialStore.values[credential] == legacyValue)
            #expect(UserDefaults.standard.object(forKey: legacyKey) == nil)
        }
    }

    @Test(arguments: PeekabooCredential.allCases)
    func `Failed legacy migration retains the preference`(_ credential: PeekabooCredential) throws {
        try withIsolatedSettingsEnvironment { _, credentialStore in
            let legacyValue = "legacy-\(credential.rawValue)"
            let legacyKey = "peekaboo.\(credential.rawValue)"
            UserDefaults.standard.set(legacyValue, forKey: legacyKey)
            credentialStore.writeFailures.insert(credential)

            let settings = PeekabooSettings(credentialStore: credentialStore)

            #expect(self.value(for: credential, in: settings) == legacyValue)
            #expect(credentialStore.values[credential] == nil)
            #expect(UserDefaults.standard.string(forKey: legacyKey) == legacyValue)
        }
    }

    @Test(arguments: PeekabooCredential.allCases)
    func `Existing Keychain credentials win over legacy preferences`(_ credential: PeekabooCredential) throws {
        try withIsolatedSettingsEnvironment { _, credentialStore in
            let storedValue = "stored-\(credential.rawValue)"
            let legacyKey = "peekaboo.\(credential.rawValue)"
            credentialStore.values[credential] = storedValue
            UserDefaults.standard.set("legacy-\(credential.rawValue)", forKey: legacyKey)

            let settings = PeekabooSettings(credentialStore: credentialStore)

            #expect(self.value(for: credential, in: settings) == storedValue)
            #expect(credentialStore.values[credential] == storedValue)
            #expect(UserDefaults.standard.object(forKey: legacyKey) == nil)
        }
    }

    @Test(arguments: PeekabooCredential.allCases)
    func `Unreadable Keychain does not consume legacy state`(_ credential: PeekabooCredential) throws {
        try withIsolatedSettingsEnvironment { _, credentialStore in
            let legacyValue = "legacy-\(credential.rawValue)"
            let legacyKey = "peekaboo.\(credential.rawValue)"
            UserDefaults.standard.set(legacyValue, forKey: legacyKey)
            credentialStore.readFailures.insert(credential)

            let settings = PeekabooSettings(credentialStore: credentialStore)

            #expect(self.value(for: credential, in: settings).isEmpty)
            #expect(UserDefaults.standard.string(forKey: legacyKey) == legacyValue)
        }
    }

    @Test(arguments: PeekabooCredential.allCases)
    func `Credentials save reload and delete through the store`(_ credential: PeekabooCredential) throws {
        try withIsolatedSettingsEnvironment { _, credentialStore in
            let value = "saved-\(credential.rawValue)"
            let legacyKey = "peekaboo.\(credential.rawValue)"
            let settings = PeekabooSettings(credentialStore: credentialStore)

            self.setValue(value, for: credential, in: settings)

            #expect(credentialStore.values[credential] == value)
            #expect(UserDefaults.standard.object(forKey: legacyKey) == nil)

            let reloaded = PeekabooSettings(credentialStore: credentialStore)
            #expect(self.value(for: credential, in: reloaded) == value)

            self.setValue("", for: credential, in: reloaded)
            #expect(credentialStore.values[credential] == nil)

            let emptyReload = PeekabooSettings(credentialStore: credentialStore)
            #expect(self.value(for: credential, in: emptyReload).isEmpty)
        }
    }

    private func value(for credential: PeekabooCredential, in settings: PeekabooSettings) -> String {
        switch credential {
        case .openAI:
            settings.openAIAPIKey
        case .anthropic:
            settings.anthropicAPIKey
        case .grok:
            settings.grokAPIKey
        case .google:
            settings.googleAPIKey
        case .miniMax:
            settings.miniMaxAPIKey
        case .miniMaxChina:
            settings.miniMaxChinaAPIKey
        }
    }

    private func setValue(
        _ value: String,
        for credential: PeekabooCredential,
        in settings: PeekabooSettings)
    {
        switch credential {
        case .openAI:
            settings.openAIAPIKey = value
        case .anthropic:
            settings.anthropicAPIKey = value
        case .grok:
            settings.grokAPIKey = value
        case .google:
            settings.googleAPIKey = value
        case .miniMax:
            settings.miniMaxAPIKey = value
        case .miniMaxChina:
            settings.miniMaxChinaAPIKey = value
        }
    }
}
