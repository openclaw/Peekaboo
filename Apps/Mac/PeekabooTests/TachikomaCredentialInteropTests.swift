import Darwin
import Foundation
import PeekabooAutomation
import Tachikoma
import Testing
@testable import Peekaboo

/// Foundation's atomic writer needs OS-managed replacement directories outside the local proof sandbox.
/// Run only in the secretless hosted Mac lane, which uses `swift test --no-parallel`.
@Suite(.serialized)
@MainActor
struct TachikomaCredentialInteropTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" &&
            ProcessInfo.processInfo.environment["RUNNER_ENVIRONMENT"] == "github-hosted" &&
            ProcessInfo.processInfo.environment["RUNNER_OS"] == "macOS"))
    func `sequential Tachikoma writer and app coordinator share the credential file`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-tachikoma-interop-\(UUID().uuidString)", isDirectory: true)
        let fixture = CredentialCoordinatorFixture(directory: directory)
        // The profile is process-global. Serial execution and no awaits keep the override scoped to this call.
        // Set it before accessing even TKAuthManager.shared; never load the caller's original profile.
        let previousProfile = TachikomaConfiguration.profileDirectoryName
        TachikomaConfiguration.profileDirectoryName = directory.path
        defer { TachikomaConfiguration.profileDirectoryName = previousProfile }

        let previousEnvironment = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        let environmentSet = setenv("ANTHROPIC_API_KEY", "synthetic-environment-only", 1) == 0
        try #require(environmentSet)
        defer {
            if let previousEnvironment {
                setenv("ANTHROPIC_API_KEY", previousEnvironment, 1)
            } else {
                unsetenv("ANTHROPIC_API_KEY")
            }
        }

        var expected = [
            "OPENAI_API_KEY": "synthetic-app-original",
            "X_AI_API_KEY": "synthetic-grok-canonical",
            "XAI_API_KEY": "synthetic-grok-alias",
            "GROK_API_KEY": "synthetic-grok-other-alias",
            "GEMINI_API_KEY": "synthetic-google-canonical",
            "GOOGLE_API_KEY": "synthetic-google-alias",
            "MINIMAX_API_KEY": "synthetic-international",
            "MINIMAX_CN_API_KEY": "synthetic-china",
            "UNRELATED_API_KEY": "synthetic-unrelated",
            "OPENAI_ACCESS_TOKEN": "synthetic-oauth-access==",
            "OPENAI_REFRESH_TOKEN": "synthetic-oauth-refresh==",
            "OPENAI_ACCESS_EXPIRES": "4102444800",
        ]
        _ = try fixture.file.updateCredentials { $0 = expected }
        let coordinator = fixture.coordinator()
        let initialLoadMatches = coordinator.state(for: .openAI).confirmed == expected["OPENAI_API_KEY"]
        try #require(initialLoadMatches)
        #expect(fixture.runtimeRefreshes == 1)

        // Exercise the pinned production writer, without provider validation, auth resolution, or OAuth.
        try TKAuthManager.shared.setCredential(key: "OPENAI_API_KEY", value: "synthetic-tachikoma-rotation==")
        expected["OPENAI_API_KEY"] = "synthetic-tachikoma-rotation=="
        let coreReadsTachikoma = try fixture.file.readCredentialSnapshot() == expected
        try #require(coreReadsTachikoma)
        let coordinatorStillNeedsReload = coordinator.state(for: .openAI).confirmed == "synthetic-app-original"
        #expect(coordinatorStillNeedsReload)
        coordinator.reload()
        let reloadObservedRotation = coordinator.state(for: .openAI).confirmed == expected["OPENAI_API_KEY"]
        #expect(reloadObservedRotation)
        #expect(!coordinator.reloadFailed)
        #expect(fixture.runtimeRefreshes == 2)

        coordinator.edit("synthetic-app-google-edit", for: .google)
        expected["GEMINI_API_KEY"] = "synthetic-app-google-edit"
        expected.removeValue(forKey: "GOOGLE_API_KEY")
        let appEditPreservesRotationAndOAuth = TKCredentialStore().load() == expected
        #expect(appEditPreservesRotationAndOAuth)
        #expect(coordinator.state(for: .google).failure == nil)
        #expect(fixture.runtimeRefreshes == 3)

        coordinator.edit("", for: .grok)
        for key in ["X_AI_API_KEY", "XAI_API_KEY", "GROK_API_KEY"] {
            expected.removeValue(forKey: key)
        }
        let freshAfterClear = TKCredentialStore().load()
        let familyAbsent = ["X_AI_API_KEY", "XAI_API_KEY", "GROK_API_KEY"].allSatisfy { freshAfterClear[$0] == nil }
        #expect(familyAbsent)
        let otherEntriesSurviveClear = freshAfterClear == expected
        #expect(otherEntriesSurviveClear)
        #expect(coordinator.state(for: .grok).failure == nil)

        coordinator.edit("", for: .miniMaxChina)
        expected.removeValue(forKey: "MINIMAX_CN_API_KEY")
        let finalSnapshot = TKCredentialStore().load()
        let chinaClearedInternationalPreserved = finalSnapshot["MINIMAX_CN_API_KEY"] == nil &&
            finalSnapshot["MINIMAX_API_KEY"] == "synthetic-international"
        #expect(chinaClearedInternationalPreserved)
        let environmentNeverPersisted = finalSnapshot["ANTHROPIC_API_KEY"] == nil &&
            !finalSnapshot.values.contains("synthetic-environment-only")
        #expect(environmentNeverPersisted)
        let environmentNotConfirmed = coordinator.state(for: .anthropic).confirmed.isEmpty
        #expect(environmentNotConfirmed)
        #expect(coordinator.state(for: .miniMaxChina).failure == nil)
        #expect(fixture.runtimeRefreshes == 5)
        let finalContentsMatch = try fixture.file.readCredentialSnapshot() == expected && finalSnapshot == expected
        #expect(finalContentsMatch)
    }
}
