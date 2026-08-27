import Foundation
import Security

enum PeekabooCredential: String, CaseIterable, Sendable {
    case openAI = "openAIAPIKey"
    case anthropic = "anthropicAPIKey"
    case grok = "grokAPIKey"
    case google = "googleAPIKey"
    case miniMax = "miniMaxAPIKey"
    case miniMaxChina = "miniMaxChinaAPIKey"
}

protocol CredentialStore {
    func value(for credential: PeekabooCredential) throws -> String?
    func setValue(_ value: String, for credential: PeekabooCredential) throws
    func removeValue(for credential: PeekabooCredential) throws
}

enum KeychainCredentialStoreError: Error, Equatable {
    case invalidData
    case unexpectedStatus(OSStatus)
}

struct KeychainCredentialStore: CredentialStore {
    private let service: String

    init(service: String = KeychainCredentialStore.defaultService) {
        self.service = service
    }

    func value(for credential: PeekabooCredential) throws -> String? {
        var query = self.query(for: credential)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8)
            else {
                throw KeychainCredentialStoreError.invalidData
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainCredentialStoreError.unexpectedStatus(status)
        }
    }

    func setValue(_ value: String, for credential: PeekabooCredential) throws {
        let data = Data(value.utf8)
        let query = self.query(for: credential)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainCredentialStoreError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainCredentialStoreError.unexpectedStatus(updateStatus)
        }
    }

    func removeValue(for credential: PeekabooCredential) throws {
        let status = SecItemDelete(self.query(for: credential) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialStoreError.unexpectedStatus(status)
        }
    }

    private func query(for credential: PeekabooCredential) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: credential.rawValue,
        ]
    }

    private static var defaultService: String {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "boo.peekaboo.mac"
        return "\(bundleIdentifier).provider-credentials"
    }
}
