import Foundation
import Tachikoma

@available(macOS 14.0, *)
@MainActor
struct ProviderStatusReporter {
    private let timeoutSeconds: Double

    init(timeoutSeconds: Double) {
        self.timeoutSeconds = timeoutSeconds > 0 ? timeoutSeconds : 30
    }

    func summary() async -> ProviderStatusSummary {
        let statuses = await self.providerStatuses()
        return ProviderStatusSummary(providers: statuses)
    }

    func printSummary() async {
        let summary = await self.summary()
        print("Providers:")
        for provider in summary.providers {
            print("  \(provider.name): \(provider.message)")
        }
    }

    private func providerStatuses() async -> [ProviderCredentialStatus] {
        var statuses: [ProviderCredentialStatus] = []
        for pid in [TKProviderId.openai, .anthropic, .grok, .gemini, .openrouter] {
            let status = await self.status(for: pid)
            statuses.append(status)
        }
        return statuses
    }

    private func status(for pid: TKProviderId) async -> ProviderCredentialStatus {
        switch self.source(for: pid) {
        case let .env(key, value):
            let validation = await TKAuthManager.shared.validate(
                provider: pid,
                secret: value,
                timeout: self.timeoutSeconds
            )
            return self.makeStatus(for: pid, source: .init(type: "env", key: key), validation: validation)
        case let .credentials(key, value):
            let validation = await TKAuthManager.shared.validate(
                provider: pid,
                secret: value,
                timeout: self.timeoutSeconds
            )
            return self.makeStatus(for: pid, source: .init(type: "credentials", key: key), validation: validation)
        case let .missing(reason):
            return ProviderCredentialStatus(
                id: pid.rawValue,
                name: pid.displayName,
                state: .missing,
                source: nil,
                validation: nil,
                message: reason
            )
        }
    }

    private func makeStatus(
        for pid: TKProviderId,
        source: ProviderCredentialSource,
        validation: TKValidationResult
    ) -> ProviderCredentialStatus {
        switch validation {
        case .success:
            ProviderCredentialStatus(
                id: pid.rawValue,
                name: pid.displayName,
                state: .ready,
                source: source,
                validation: .validated,
                message: "ready (\(source.description), validated)"
            )
        case let .failure(reason):
            ProviderCredentialStatus(
                id: pid.rawValue,
                name: pid.displayName,
                state: .stored,
                source: source,
                validation: .failed,
                message: "stored (\(source.description), validation failed: \(reason))"
            )
        case let .timeout(seconds):
            ProviderCredentialStatus(
                id: pid.rawValue,
                name: pid.displayName,
                state: .stored,
                source: source,
                validation: .timedOut,
                message: "stored (\(source.description), validation timed out after \(Int(seconds))s)"
            )
        }
    }

    private func source(for pid: TKProviderId) -> ProviderSource {
        if let source = self.envSource(for: pid) {
            return source
        }

        if let source = self.credentialSource(for: pid) {
            return source
        }

        return .missing("missing")
    }

    private func envSource(for pid: TKProviderId) -> ProviderSource? {
        let env = ProcessInfo.processInfo.environment
        switch pid {
        case .openai:
            if let v = env["OPENAI_API_KEY"], !v.isEmpty { return .env("OPENAI_API_KEY", v) }
        case .anthropic:
            if let v = env["ANTHROPIC_API_KEY"], !v.isEmpty { return .env("ANTHROPIC_API_KEY", v) }
        case .grok:
            for k in ["GROK_API_KEY", "X_AI_API_KEY", "XAI_API_KEY"] {
                if let v = env[k], !v.isEmpty { return .env(k, v) }
            }
        case .gemini:
            if let v = env["GEMINI_API_KEY"], !v.isEmpty { return .env("GEMINI_API_KEY", v) }
        case .openrouter:
            if let v = env["OPENROUTER_API_KEY"], !v.isEmpty { return .env("OPENROUTER_API_KEY", v) }
        }
        return nil
    }

    private func credentialSource(for pid: TKProviderId) -> ProviderSource? {
        let creds = TKAuthManager.shared
        switch pid {
        case .openai:
            if let v = creds
                .credentialValue(for: "OPENAI_ACCESS_TOKEN") { return .credentials("OPENAI_ACCESS_TOKEN", v) }
            if let v = creds.credentialValue(for: "OPENAI_API_KEY") { return .credentials("OPENAI_API_KEY", v) }
        case .anthropic:
            if let v = creds.credentialValue(for: "ANTHROPIC_ACCESS_TOKEN") { return .credentials(
                "ANTHROPIC_ACCESS_TOKEN",
                v
            ) }
            if let v = creds.credentialValue(for: "ANTHROPIC_API_KEY") { return .credentials("ANTHROPIC_API_KEY", v) }
        case .grok:
            for k in ["GROK_API_KEY", "X_AI_API_KEY", "XAI_API_KEY"] {
                if let v = creds.credentialValue(for: k) { return .credentials(k, v) }
            }
        case .gemini:
            if let v = creds.credentialValue(for: "GEMINI_API_KEY") { return .credentials("GEMINI_API_KEY", v) }
        case .openrouter:
            if let v = creds.credentialValue(for: "OPENROUTER_API_KEY") {
                return .credentials("OPENROUTER_API_KEY", v)
            }
        }
        return nil
    }
}

private enum ProviderSource {
    case env(String, String)
    case credentials(String, String)
    case missing(String)
}

struct ProviderStatusSummary: Codable {
    let providers: [ProviderCredentialStatus]
}

struct ProviderCredentialStatus: Codable {
    let id: String
    let name: String
    let state: ProviderCredentialState
    let source: ProviderCredentialSource?
    let validation: ProviderCredentialValidation?
    let message: String
}

enum ProviderCredentialState: String, Codable {
    case missing
    case ready
    case stored
}

struct ProviderCredentialSource: Codable {
    let type: String
    let key: String

    var description: String {
        "\(self.type) \(self.key)"
    }
}

enum ProviderCredentialValidation: String, Codable {
    case validated
    case failed
    case timedOut = "timed_out"
}
