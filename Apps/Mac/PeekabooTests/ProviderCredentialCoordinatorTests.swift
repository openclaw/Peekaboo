import Darwin
import Foundation
import os
import PeekabooAutomation
import Testing
@testable import Peekaboo

@Suite(.serialized)
@MainActor
struct ProviderCredentialCoordinatorTests {
    @Test(arguments: PeekabooCredential.allCases)
    func `unchanged empty bindings preserve all legacy recovery entries`(_ credential: PeekabooCredential) throws {
        let fixture = CredentialCoordinatorFixture()
        for family in PeekabooCredential.allCases {
            fixture.preferences[family] = "synthetic-legacy"
        }
        let file = CountingFile(file: fixture.file)
        let coordinator = ProviderCredentialCoordinator(
            file: file,
            legacy: LegacyCredentialPreferences(
                read: { fixture.preferences[$0] },
                remove: { fixture.preferences.removeValue(forKey: $0) }),
            runtimeDidChange: { fixture.runtimeRefreshes += 1 })

        coordinator.edit("", for: credential)
        coordinator.edit("", for: credential)
        coordinator.edit(" \t\r\n\u{00A0}", for: credential)

        #expect(file.updateCount == 0)
        #expect(fixture.runtimeRefreshes == 1)
        #expect(fixture.preferences.count == PeekabooCredential.allCases.count)
        #expect(coordinator.recoverable == Set(PeekabooCredential.allCases))
        #expect(!FileManager.default.fileExists(atPath: fixture.file.url.path))
        #expect(try fixture.file.readCredentialSnapshot().isEmpty)
    }

    @Test(arguments: PeekabooCredential.allCases)
    func `unchanged populated bindings never rewrite or replace an independent rotation`(
        _ credential: PeekabooCredential) throws
    {
        let fixture = CredentialCoordinatorFixture()
        fixture.preferences[credential] = "synthetic-legacy"
        _ = try fixture.file.updateCredentials { credential.replace(in: &$0, with: "synthetic-original") }
        let file = CountingFile(file: fixture.file)
        let coordinator = ProviderCredentialCoordinator(
            file: file,
            legacy: LegacyCredentialPreferences(
                read: { fixture.preferences[$0] },
                remove: { fixture.preferences.removeValue(forKey: $0) }),
            runtimeDidChange: { fixture.runtimeRefreshes += 1 })

        coordinator.edit("synthetic-original", for: credential)
        #expect(file.updateCount == 0)
        _ = try fixture.file.updateCredentials { credential.replace(in: &$0, with: "synthetic-independent-rotation") }
        coordinator.edit("synthetic-original", for: credential)
        coordinator.edit(" \t\nsynthetic-original\r\n ", for: credential)

        #expect(file.updateCount == 0)
        #expect(fixture.runtimeRefreshes == 1)
        #expect(fixture.preferences.count == 1)
        let rotationPreserved = try credential.value(in: fixture.file.readCredentialSnapshot()) ==
            "synthetic-independent-rotation"
        #expect(rotationPreserved)
        coordinator.reload()
        let rotationObserved = coordinator.state(for: credential).confirmed == "synthetic-independent-rotation"
        #expect(rotationObserved)
        #expect(fixture.runtimeRefreshes == 2)
    }

    @Test(arguments: PeekabooCredential.allCases)
    func `surrounding whitespace edits save and blank edits clear`(_ credential: PeekabooCredential) throws {
        let fixture = CredentialCoordinatorFixture()
        fixture.preferences[credential] = "synthetic-legacy"
        let file = CountingFile(file: fixture.file)
        let coordinator = self.coordinator(fixture, file: file)
        coordinator.edit(" \t\n\u{00A0}synthetic-interior space=value\u{00A0}\r\n ", for: credential)

        let normalized = "synthetic-interior space=value"
        #expect(coordinator.state(for: credential).draft == normalized)
        #expect(coordinator.state(for: credential).confirmed == normalized)
        #expect(coordinator.state(for: credential).failure == nil)
        #expect(try credential.value(in: fixture.file.readCredentialSnapshot()) == normalized)
        #expect(fixture.preferences.isEmpty)
        #expect(file.updateCount == 1)
        #expect(fixture.runtimeRefreshes == 2)

        fixture.preferences[credential] = "synthetic-recovery"
        coordinator.edit(" \t\r\n ", for: credential)
        #expect(coordinator.state(for: credential).draft.isEmpty)
        #expect(coordinator.state(for: credential).confirmed.isEmpty)
        #expect(coordinator.state(for: credential).failure == nil)
        #expect(try fixture.file.readCredentialSnapshot().isEmpty)
        #expect(fixture.preferences.isEmpty)
        #expect(file.updateCount == 2)
        #expect(fixture.runtimeRefreshes == 3)
    }

    @Test(arguments: ["", " \t\r\n\u{00A0}"])
    func `blank legacy entries stay stored without offering recovery`(_ blank: String) throws {
        let fixture = CredentialCoordinatorFixture()
        for credential in PeekabooCredential.allCases {
            fixture.preferences[credential] = blank
        }
        let file = CountingFile(file: fixture.file)
        let coordinator = self.coordinator(fixture, file: file)
        coordinator.reload()

        #expect(coordinator.recoverable.isEmpty)
        #expect(fixture.preferences.count == PeekabooCredential.allCases.count)
        #expect(file.updateCount == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.file.url.path))
        coordinator.importSavedAppKeys()
        #expect(!coordinator.recoveryFailed)
        #expect(coordinator.recoverable.isEmpty)
        #expect(fixture.preferences.count == PeekabooCredential.allCases.count)
        #expect(try fixture.file.readCredentialSnapshot().isEmpty)
    }

    @Test(arguments: PeekabooCredential.allCases)
    func `mixed legacy import trims all families while fresh file values win`(
        _ existing: PeekabooCredential) throws
    {
        let fixture = CredentialCoordinatorFixture()
        for credential in PeekabooCredential.allCases {
            fixture.preferences[credential] = " \t\nsynthetic-legacy-\(credential.rawValue)\r\n "
        }
        let file = CountingFile(file: fixture.file)
        let coordinator = self.coordinator(fixture, file: file)
        #expect(coordinator.recoverable == Set(PeekabooCredential.allCases))
        #expect(file.updateCount == 0)
        _ = try fixture.file.updateCredentials {
            $0[existing.keys.last!] = "synthetic-cli-rotation"
            $0["OPENAI_REFRESH_TOKEN"] = "synthetic-oauth=="
        }
        coordinator.importSavedAppKeys()

        #expect(!coordinator.recoveryFailed)
        #expect(coordinator.recoverable.isEmpty)
        #expect(file.updateCount == 1)
        #expect(fixture.runtimeRefreshes == 2)
        #expect(fixture.preferences.count == 1)
        #expect(fixture.preferences[existing] != nil)
        let snapshot = try fixture.file.readCredentialSnapshot()
        for credential in PeekabooCredential.allCases {
            let expected = credential == existing ? "synthetic-cli-rotation" :
                "synthetic-legacy-\(credential.rawValue)"
            #expect(credential.value(in: snapshot) == expected)
            #expect(coordinator.state(for: credential).draft == expected)
        }
        #expect(snapshot["OPENAI_REFRESH_TOKEN"] == "synthetic-oauth==")
    }

    @Test(
        arguments: PeekabooCredential.allCases,
        ["synthetic-first\nsecond", "synthetic-first\r\nsecond", "synthetic-first\0second"])
    func `malformed drafts and legacy imports preserve all stored bytes`(
        _ credential: PeekabooCredential,
        _ malformed: String) throws
    {
        let fixture = CredentialCoordinatorFixture()
        _ = try fixture.file.updateCredentials { $0["OPENAI_REFRESH_TOKEN"] = "synthetic-oauth==" }
        let original = try Data(contentsOf: fixture.file.url)
        for family in PeekabooCredential.allCases {
            fixture.preferences[family] = " \tsynthetic-valid\n "
        }
        fixture.preferences[credential] = " \t\n\(malformed)\r\n "
        let preferences = fixture.preferences
        let file = CountingFile(file: fixture.file)
        let coordinator = self.coordinator(fixture, file: file)
        coordinator.edit(" \t\n\(malformed)\r\n ", for: credential)
        #expect(coordinator.state(for: credential).draft == malformed)
        #expect(coordinator.state(for: credential).confirmed.isEmpty)
        #expect(coordinator.state(for: credential).failure == .save)
        #expect(try Data(contentsOf: fixture.file.url) == original)
        coordinator.importSavedAppKeys()
        #expect(coordinator.recoveryFailed)
        #expect(coordinator.recoverable == Set(PeekabooCredential.allCases))
        #expect(fixture.preferences == preferences)
        #expect(try Data(contentsOf: fixture.file.url) == original)
        #expect(fixture.runtimeRefreshes == 1)
        #expect(file.updateCount == 2)
    }

    @Test
    func `published warnings are confirmed and never blindly retried`() throws {
        let fixture = CredentialCoordinatorFixture()
        fixture.preferences[.openAI] = "synthetic-legacy"
        let coordinator = ProviderCredentialCoordinator(
            file: WarningFile(file: fixture.file),
            legacy: LegacyCredentialPreferences(
                read: { fixture.preferences[$0] },
                remove: { fixture.preferences.removeValue(forKey: $0) }),
            runtimeDidChange: { fixture.runtimeRefreshes += 1 })
        coordinator.importSavedAppKeys()
        #expect(coordinator.recoveryDurabilityWarning)
        #expect(fixture.preferences.isEmpty)
        coordinator.edit("synthetic-published", for: .openAI)
        #expect(coordinator.state(for: .openAI).durabilityWarning)
        #expect(coordinator.state(for: .openAI).failure == nil)
        let refreshes = fixture.runtimeRefreshes
        coordinator.retry(.openAI)
        #expect(fixture.runtimeRefreshes == refreshes)
        let published = try coordinator.state(for: .openAI).confirmed ==
            PeekabooCredential.openAI.value(in: fixture.file.readCredentialSnapshot())
        #expect(published)
    }

    @Test(arguments: PeekabooCredential.allCases)
    func `save reload clear`(_ credential: PeekabooCredential) throws {
        let fixture = CredentialCoordinatorFixture()
        let coordinator = fixture.coordinator()
        coordinator.edit("synthetic-saved=value", for: credential)
        let saved = coordinator.state(for: credential).confirmed == "synthetic-saved=value"
        #expect(saved)
        #expect(coordinator.state(for: credential).failure == nil)
        let reloaded = fixture.coordinator()
        let persisted = reloaded.state(for: credential).confirmed == "synthetic-saved=value"
        #expect(persisted)
        reloaded.edit("", for: credential)
        #expect(try fixture.file.readCredentialSnapshot().isEmpty)
        #expect(fixture.coordinator().state(for: credential).confirmed.isEmpty)
        #expect(fixture.runtimeRefreshes == 5)
    }

    @Test(arguments: PeekabooCredential.allCases)
    func `explicit recovery rechecks fresh file`(_ credential: PeekabooCredential) throws {
        let fixture = CredentialCoordinatorFixture()
        fixture.preferences[credential] = "synthetic-legacy"
        let coordinator = fixture.coordinator()
        #expect(coordinator.state(for: credential).draft.isEmpty)
        #expect(coordinator.recoverable.contains(credential))
        _ = try fixture.file.updateCredentials { credential.replace(in: &$0, with: "synthetic-cli-rotation") }
        coordinator.importSavedAppKeys()
        let cliWins = coordinator.state(for: credential).confirmed == "synthetic-cli-rotation"
        #expect(cliWins)
        coordinator.edit("", for: credential)
        #expect(fixture.preferences[credential] == nil)
        #expect(fixture.coordinator().recoverable.isEmpty)
    }

    @Test(arguments: ["", "# comment only\n"])
    func `empty file does not recover automatically`(_ contents: String) throws {
        let fixture = CredentialCoordinatorFixture()
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try contents.write(to: fixture.file.url, atomically: false, encoding: .utf8)
        for credential in PeekabooCredential.allCases {
            fixture.preferences[credential] = "synthetic-legacy"
        }
        let coordinator = fixture.coordinator()
        #expect(coordinator.recoverable.count == 6)
        #expect(try fixture.file.readCredentialSnapshot().isEmpty)
        coordinator.importSavedAppKeys()
        #expect(!coordinator.recoveryFailed)
        #expect(fixture.preferences.isEmpty)
        #expect(try fixture.file.readCredentialSnapshot().count == 6)
        coordinator.importSavedAppKeys()
        #expect(try fixture.file.readCredentialSnapshot().count == 6)
    }

    @Test(arguments: PeekabooCredential.allCases)
    func `failed save and clear keep confirmed state`(_ credential: PeekabooCredential) throws {
        let fixture = CredentialCoordinatorFixture()
        let coordinator = fixture.coordinator()
        coordinator.edit("synthetic-original", for: credential)
        let refreshes = fixture.runtimeRefreshes
        #expect(chmod(fixture.directory.path, 0o500) == 0)
        defer { chmod(fixture.directory.path, 0o700) }
        coordinator.edit(" \t\nsynthetic-unsaved\r\n ", for: credential)
        #expect(coordinator.state(for: credential).failure == .save)
        let unchanged = coordinator.state(for: credential).confirmed == "synthetic-original"
        #expect(unchanged)
        #expect(fixture.runtimeRefreshes == refreshes)
        coordinator.reload()
        let retainedDraft = coordinator.state(for: credential).draft == "synthetic-unsaved"
        #expect(retainedDraft)
        #expect(chmod(fixture.directory.path, 0o700) == 0)
        coordinator.edit(" \tsynthetic-revised-draft\n ", for: credential)
        #expect(coordinator.state(for: credential).draft == "synthetic-revised-draft")
        let stillOriginal = try credential.value(in: fixture.file.readCredentialSnapshot()) == "synthetic-original"
        #expect(stillOriginal)
        coordinator.retry(credential)
        #expect(coordinator.state(for: credential).failure == nil)
        #expect(coordinator.state(for: credential).confirmed == "synthetic-revised-draft")
        #expect(chmod(fixture.directory.path, 0o500) == 0)
        coordinator.edit(" \t\n ", for: credential)
        #expect(coordinator.state(for: credential).failure == .clear)
        #expect(!coordinator.state(for: credential).confirmed.isEmpty)
        #expect(coordinator.state(for: credential).draft.isEmpty)
        #expect(chmod(fixture.directory.path, 0o700) == 0)
        coordinator.edit("\r\n ", for: credential)
        #expect(coordinator.state(for: credential).failure == .clear)
        coordinator.retry(credential)
        #expect(coordinator.state(for: credential).confirmed.isEmpty)
        #expect(try fixture.file.readCredentialSnapshot().isEmpty)
    }

    @Test
    func `aliases and unrelated O auth survive rotation`() throws {
        let fixture = CredentialCoordinatorFixture()
        _ = try fixture.file.updateCredentials { snapshot in
            for credential in PeekabooCredential.allCases {
                for key in credential.keys {
                    snapshot[key] = "synthetic-alias"
                }
            }
            snapshot["OPENAI_REFRESH_TOKEN"] = "synthetic-oauth=="
            snapshot["UNRELATED_API_KEY"] = "synthetic-unrelated"
        }
        let coordinator = fixture.coordinator()
        coordinator.edit("", for: .grok)
        coordinator.edit("synthetic-google", for: .google)
        coordinator.edit("", for: .miniMaxChina)
        let snapshot = try fixture.file.readCredentialSnapshot()
        #expect(PeekabooCredential.grok.keys.allSatisfy { snapshot[$0] == nil })
        #expect(snapshot["GOOGLE_API_KEY"] == nil)
        #expect(snapshot["MINIMAX_CN_API_KEY"] == nil)
        #expect(snapshot["MINIMAX_API_KEY"] != nil)
        let preserved = snapshot["OPENAI_REFRESH_TOKEN"] == "synthetic-oauth==" &&
            snapshot["UNRELATED_API_KEY"] == "synthetic-unrelated"
        #expect(preserved)
        _ = try fixture.file.updateCredentials { $0["OPENAI_API_KEY"] = "synthetic-cli-new" }
        coordinator.edit("synthetic-other-edit", for: .anthropic)
        let fresh = coordinator.state(for: .openAI).confirmed == "synthetic-cli-new"
        #expect(fresh)
        _ = try fixture.file.updateCredentials { $0.removeValue(forKey: "OPENAI_API_KEY") }
        coordinator.reload()
        #expect(coordinator.state(for: .openAI).confirmed.isEmpty)
    }

    @Test
    func `unreadable and invalid files never trigger recovery`() throws {
        let fixture = CredentialCoordinatorFixture()
        fixture.preferences[.openAI] = "synthetic-legacy"
        _ = try fixture.file.updateCredentials { $0["OPENAI_API_KEY"] = "synthetic-saved" }
        let coordinator = fixture.coordinator()
        #expect(chmod(fixture.file.url.path, 0) == 0)
        defer { chmod(fixture.file.url.path, 0o600) }
        coordinator.reload()
        #expect(coordinator.reloadFailed)
        coordinator.importSavedAppKeys()
        #expect(coordinator.recoveryFailed)
        #expect(fixture.preferences.count == 1)
        #expect(chmod(fixture.file.url.path, 0o600) == 0)
        coordinator.edit("synthetic-recovered-write", for: .openAI)
        #expect(!coordinator.reloadFailed)
        try "invalid line".write(to: fixture.file.url, atomically: false, encoding: .utf8)
        coordinator.edit("synthetic-draft", for: .openAI)
        #expect(coordinator.state(for: .openAI).failure == .save)
        let unchanged = try String(contentsOf: fixture.file.url, encoding: .utf8) == "invalid line"
        #expect(unchanged)
    }

    private func coordinator(
        _ fixture: CredentialCoordinatorFixture,
        file: CountingFile) -> ProviderCredentialCoordinator
    {
        ProviderCredentialCoordinator(
            file: file,
            legacy: LegacyCredentialPreferences(
                read: { fixture.preferences[$0] },
                remove: { fixture.preferences.removeValue(forKey: $0) }),
            runtimeDidChange: { fixture.runtimeRefreshes += 1 })
    }
}

private struct CountingFile: CredentialFileAccess {
    let file: CredentialFile
    private let updates = OSAllocatedUnfairLock(initialState: 0)

    var updateCount: Int {
        self.updates.withLock { $0 }
    }

    func readCredentialSnapshot() throws -> [String: String] {
        try self.file.readCredentialSnapshot()
    }

    func updateCredentials(_ edit: (inout [String: String]) throws -> Void) throws -> CredentialFile.Publication {
        self.updates.withLock { $0 += 1 }
        return try self.file.updateCredentials(edit)
    }
}

private struct WarningFile: CredentialFileAccess {
    let file: CredentialFile

    func readCredentialSnapshot() throws -> [String: String] {
        try self.file.readCredentialSnapshot()
    }

    func updateCredentials(_ edit: (inout [String: String]) throws -> Void) throws -> CredentialFile.Publication {
        let publication = try self.file.updateCredentials(edit)
        return CredentialFile.Publication(snapshot: publication.snapshot, durabilityWarning: true)
    }
}
