import Foundation

extension ConfigurationManager {
    /// Load credentials from file
    func loadCredentials() {
        self.withStateLock {
            guard FileManager.default.fileExists(atPath: Self.credentialsPath) else {
                return
            }

            do {
                let contents = try String(contentsOfFile: Self.credentialsPath)
                let lines = contents.components(separatedBy: .newlines)

                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty || trimmed.hasPrefix("#") {
                        continue
                    }

                    if let equalIndex = trimmed.firstIndex(of: "=") {
                        let key = String(trimmed[..<equalIndex]).trimmingCharacters(in: .whitespaces)
                        let value = String(trimmed[trimmed.index(after: equalIndex)...])
                            .trimmingCharacters(in: .whitespaces)
                        if !key.isEmpty, !value.isEmpty {
                            self.credentials[key] = value
                        }
                    }
                }
            } catch {
                // Silently ignore credential loading errors.
            }
        }
    }

    /// Save credentials to file with proper permissions
    public func saveCredentials(_ newCredentials: [String: String]) throws {
        try self.withStateLock {
            newCredentials.forEach { self.credentials[$0.key] = $0.value }

            try FileManager.default.createDirectory(
                atPath: Self.baseDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])

            let header = [
                "# Peekaboo credentials file",
                "# This file contains sensitive API keys and should not be shared",
                "",
            ]
            let body = self.credentials.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }
            let content = (header + body).joined(separator: "\n")

            try content.write(
                to: URL(fileURLWithPath: Self.credentialsPath),
                atomically: true,
                encoding: .utf8)

            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: Self.credentialsPath)
        }
    }

    /// Set or update a credential
    public func setCredential(key: String, value: String) throws {
        try self.withStateLock {
            self.loadCredentials()
            try self.saveCredentials([key: value])
        }
    }

    public func removeCredential(key: String) throws {
        try self.withStateLock {
            self.loadCredentials()
            self.credentials.removeValue(forKey: key)

            if self.credentials.isEmpty {
                if FileManager.default.fileExists(atPath: Self.credentialsPath) {
                    try FileManager.default.removeItem(atPath: Self.credentialsPath)
                }
                return
            }

            try self.saveCredentials([:])
        }
    }

    func validOAuthAccessToken(prefix: String) -> String? {
        self.withStateLock {
            self.loadCredentials()
            let tokenKey = "\(prefix)_ACCESS_TOKEN"
            let expiryKey = "\(prefix)_ACCESS_EXPIRES"

            if let environmentToken = self.environmentValue(for: tokenKey),
               self.isOAuthAccessTokenValid(
                   environmentToken,
                   expiry: self.environmentValue(for: expiryKey),
               )
            {
                return environmentToken
            }
            if let storedToken = self.credentials[tokenKey],
               self.isOAuthAccessTokenValid(storedToken, expiry: self.credentials[expiryKey])
            {
                return storedToken
            }
            return nil
        }
    }

    private func isOAuthAccessTokenValid(_ token: String, expiry: String?) -> Bool {
        guard !token.isEmpty else { return false }
        guard let expiry, let expiryInterval = TimeInterval(expiry) else { return true }
        return Date(timeIntervalSince1970: expiryInterval) > Date()
    }

    func hasOAuthRefreshToken(prefix: String) -> Bool {
        self.withStateLock {
            self.loadCredentials()
            let key = "\(prefix)_REFRESH_TOKEN"
            let token = self.environmentValue(for: key) ?? self.credentials[key]
            return token?.isEmpty == false
        }
    }

    /// Read a credential by key (loads from disk if needed)
    public func credentialValue(for key: String) -> String? {
        self.withStateLock {
            self.loadCredentials()
            return self.credentials[key]
        }
    }
}
