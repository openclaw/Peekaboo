import Foundation
import Tachikoma

@available(macOS 14.0, *)
@MainActor
struct ProviderStatusReporter {
    private let timeoutSeconds: Double

    init(timeoutSeconds: Double) {
        self.timeoutSeconds = timeoutSeconds > 0 ? timeoutSeconds : 30
    }

    func printSummary() async {
        print("Providers:")
        for pid in [TKProviderId.openai, .anthropic, .grok, .gemini, .openrouter] {
            let status = await self.status(for: pid)
            print("  \(pid.displayName): \(status)")
        }
    }

    private func status(for pid: TKProviderId) async -> String {
        switch self.source(for: pid) {
        case let .env(key, value):
            let validation = await TKAuthManager.shared.validate(
                provider: pid,
                secret: value,
                timeout: self.timeoutSeconds
            )
            return self.describe(source: "env \(key)", validation: validation)
        case let .credentials(key, value):
            let validation = await TKAuthManager.shared.validate(
                provider: pid,
                secret: value,
                timeout: self.timeoutSeconds
            )
            return self.describe(source: "credentials \(key)", validation: validation)
        case let .missing(reason):
            return reason
        }
    }

    private func describe(source: String, validation: TKValidationResult) -> String {
        switch validation {
        case .success:
            "ready (\(source), validated)"
        case let .failure(reason):
            "stored (\(source), validation failed: \(reason))"
        case let .timeout(seconds):
            "stored (\(source), validation timed out after \(Int(seconds))s)"
        }
    }

    private func source(for pid: TKProviderId) -> ProviderSource {
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

        return .missing("missing")
    }
}

private enum ProviderSource {
    case env(String, String)
    case credentials(String, String)
    case missing(String)
}
