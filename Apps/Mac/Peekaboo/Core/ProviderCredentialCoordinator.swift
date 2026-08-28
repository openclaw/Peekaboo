import Foundation
import Observation
import PeekabooAutomation

enum PeekabooCredential: String, CaseIterable, Sendable {
    case openAI = "openAIAPIKey"
    case anthropic = "anthropicAPIKey"
    case grok = "grokAPIKey"
    case google = "googleAPIKey"
    case miniMax = "miniMaxAPIKey"
    case miniMaxChina = "miniMaxChinaAPIKey"

    var keys: [String] {
        switch self {
        case .openAI: ["OPENAI_API_KEY"]
        case .anthropic: ["ANTHROPIC_API_KEY"]
        case .grok: ["X_AI_API_KEY", "XAI_API_KEY", "GROK_API_KEY"]
        case .google: ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
        case .miniMax: ["MINIMAX_API_KEY"]
        case .miniMaxChina: ["MINIMAX_CN_API_KEY"]
        }
    }

    func value(in snapshot: [String: String]) -> String {
        self.keys.compactMap { snapshot[$0] }.first { !$0.isEmpty } ?? ""
    }

    func replace(in snapshot: inout [String: String], with value: String) {
        for key in self.keys {
            snapshot.removeValue(forKey: key)
        }
        if !value.isEmpty {
            snapshot[self.keys[0]] = value
        }
    }
}

/// Only the six named preferences are accessible; fixtures supply an owned adapter, never standard defaults.
struct LegacyCredentialPreferences {
    var read: (PeekabooCredential) -> String?
    var remove: (PeekabooCredential) -> Void
}

@Observable
@MainActor
final class ProviderCredentialCoordinator {
    enum EditFailure: Equatable {
        case save, clear
    }

    struct State {
        var confirmed = ""
        var draft = ""
        var failure: EditFailure?
        var durabilityWarning = false
    }

    private(set) var states: [PeekabooCredential: State] = [:]
    private(set) var recoverable: Set<PeekabooCredential> = []
    private(set) var reloadFailed = false
    private(set) var recoveryFailed = false
    private(set) var recoveryDurabilityWarning = false
    @ObservationIgnored private let file: any CredentialFileAccess
    @ObservationIgnored private let legacy: LegacyCredentialPreferences
    @ObservationIgnored var runtimeDidChange: () -> Void

    init(
        file: any CredentialFileAccess,
        legacy: LegacyCredentialPreferences,
        runtimeDidChange: @escaping () -> Void)
    {
        self.file = file
        self.legacy = legacy
        self.runtimeDidChange = runtimeDidChange
        self.reload()
    }

    func state(for credential: PeekabooCredential) -> State {
        self.states[credential] ?? State()
    }

    func reload() {
        do {
            try self.accept(self.file.readCredentialSnapshot())
            self.reloadFailed = false
        } catch {
            self.reloadFailed = true
        }
    }

    func edit(_ value: String, for credential: PeekabooCredential) {
        let value = Self.normalized(value)
        var state = self.state(for: credential)
        // SwiftUI can replay an unchanged binding; it must not retire legacy keys or overwrite a file rotation.
        guard value != state.draft else { return }
        state.draft = value
        self.states[credential] = state
        // After a failure, typing only edits the unsaved draft. Retrying is always explicit.
        guard state.failure == nil else { return }
        self.save(credential)
    }

    func retry(_ credential: PeekabooCredential) {
        guard self.state(for: credential).failure != nil else { return }
        self.save(credential)
    }

    func importSavedAppKeys() {
        var imported: Set<PeekabooCredential> = []
        do {
            let publication = try self.file.updateCredentials { snapshot in
                for credential in PeekabooCredential.allCases where credential.value(in: snapshot).isEmpty {
                    let value = Self.normalized(self.legacy.read(credential) ?? "")
                    guard !value.isEmpty else { continue }
                    credential.replace(in: &snapshot, with: value)
                    imported.insert(credential)
                }
            }
            for credential in imported {
                self.legacy.remove(credential)
            }
            self.recoveryFailed = false
            self.recoveryDurabilityWarning = publication.durabilityWarning
            self.accept(publication.snapshot)
        } catch {
            self.recoveryFailed = true
        }
    }

    private func save(_ credential: PeekabooCredential) {
        let draft = self.state(for: credential).draft
        do {
            let publication = try self.file.updateCredentials { snapshot in
                credential.replace(in: &snapshot, with: draft)
            }
            self.legacy.remove(credential)
            self.states[credential] = State(
                confirmed: credential.value(in: publication.snapshot),
                draft: draft,
                durabilityWarning: publication.durabilityWarning)
            self.accept(publication.snapshot)
        } catch {
            self.states[credential]?.failure = draft.isEmpty ? .clear : .save
        }
    }

    private func accept(_ snapshot: [String: String]) {
        self.reloadFailed = false
        for credential in PeekabooCredential.allCases {
            var state = self.state(for: credential)
            state.confirmed = credential.value(in: snapshot)
            if state.failure == nil {
                state.draft = state.confirmed
            }
            self.states[credential] = state
        }
        self.recoverable = Set(PeekabooCredential.allCases.filter {
            $0.value(in: snapshot).isEmpty && !Self.normalized(self.legacy.read($0) ?? "").isEmpty
        })
        self.runtimeDidChange()
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
