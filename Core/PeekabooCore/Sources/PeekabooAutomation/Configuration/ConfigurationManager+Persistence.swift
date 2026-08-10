import Foundation
import PeekabooFoundation

extension ConfigurationManager {
    /// Create default configuration file
    public func createDefaultConfiguration() throws {
        try self.withStateLock {
            try FileManager.default.createDirectory(
                atPath: Self.baseDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])

            try ConfigurationDefaults.configurationTemplate.write(
                to: URL(fileURLWithPath: Self.configPath),
                atomically: true,
                encoding: .utf8)

            if !FileManager.default.fileExists(atPath: Self.credentialsPath) {
                try ConfigurationDefaults.sampleCredentials.write(
                    to: URL(fileURLWithPath: Self.credentialsPath),
                    atomically: true,
                    encoding: .utf8)

                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: Self.credentialsPath)
            }
        }
    }

    /// Update configuration file with new values
    public func updateConfiguration(_ updates: (inout Configuration) -> Void) throws {
        try self.withStateLock {
            var config = self.loadConfigurationFromPath(Self.configPath) ?? self.configuration ?? Configuration()
            updates(&config)
            try self.saveConfiguration(config)
            self.configuration = config
        }
    }

    func saveConfiguration(_ config: Configuration) throws {
        try self.withStateLock {
            let data = try JSONCoding.encoder.encode(config)
            try FileManager.default.createDirectory(
                atPath: Self.baseDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try data.write(to: URL(fileURLWithPath: Self.configPath), options: .atomic)
        }
    }
}

private enum ConfigurationDefaults {
    static let configurationTemplate = """
    {
      "aiProviders": {
      "providers": "openai/gpt-5.6,anthropic/claude-opus-5"
      },
      "defaults": {
        "savePath": "~/Desktop/Screenshots",
        "imageFormat": "png",
        "captureMode": "window",
        "captureFocus": "background"
      },
      "logging": {
        "level": "info",
        "path": "~/.peekaboo/logs/peekaboo.log"
      }
    }
    """

    static let sampleCredentials = """
    # Peekaboo credentials file
    # This file contains sensitive API keys and should not be shared
    #
    # Example:
    # OPENAI_API_KEY=sk-...
    # ANTHROPIC_API_KEY=sk-ant-...
    # GEMINI_API_KEY=...
    # X_AI_API_KEY=...
    # MINIMAX_API_KEY=...
    # MINIMAX_CN_API_KEY=...
    """
}
