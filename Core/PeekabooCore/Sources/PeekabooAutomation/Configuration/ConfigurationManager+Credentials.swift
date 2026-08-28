import Foundation
import os

extension ConfigurationManager: CredentialFileAccess {
    /// A fresh owner is resolved inside the existing lock, so config-root overrides remain dynamic.
    public func readCredentialSnapshot() throws -> [String: String] {
        try self.withStateLock {
            let snapshot = try CredentialFile(url: URL(fileURLWithPath: Self.credentialsPath)).readCredentialSnapshot()
            self.credentials = snapshot
            return snapshot
        }
    }

    public func updateCredentials(
        _ edit: (inout [String: String]) throws -> Void) throws -> CredentialFile.Publication
    {
        try self.withStateLock {
            let publication = try CredentialFile(url: URL(fileURLWithPath: Self.credentialsPath))
                .updateCredentials(edit)
            self.credentials = publication.snapshot
            if publication.durabilityWarning {
                Logger(subsystem: "boo.peekaboo", category: "Credentials")
                    .warning("Credential file published, but directory durability could not be confirmed")
            }
            return publication
        }
    }

    func loadCredentials() {
        // Existing nonthrowing readers retain their last confirmed snapshot on failure, never on absence.
        _ = try? self.readCredentialSnapshot()
    }

    public func saveCredentials(_ newCredentials: [String: String]) throws {
        _ = try self.updateCredentials { snapshot in
            // The public batch API accepts empty values as clears; the file stores only nonempty entries.
            for (key, value) in newCredentials {
                snapshot[key] = value.isEmpty ? nil : value
            }
        }
    }

    public func setCredential(key: String, value: String) throws {
        try self.saveCredentials([key: value])
    }

    public func removeCredential(key: String) throws {
        _ = try self.updateCredentials { $0.removeValue(forKey: key) }
    }

    func validOAuthAccessToken(prefix: String) -> String? {
        self.withStateLock {
            self.loadCredentials()
            let tokenKey = "\(prefix)_ACCESS_TOKEN"
            let expiryKey = "\(prefix)_ACCESS_EXPIRES"

            if let environmentToken = self.environmentValue(for: tokenKey),
               self.isOAuthAccessTokenValid(
                   environmentToken,
                   expiry: self.environmentValue(for: expiryKey))
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
            if let environmentToken = self.environmentValue(for: key), !environmentToken.isEmpty {
                return true
            }
            return self.credentials[key]?.isEmpty == false
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
