import Darwin
import Foundation
import PeekabooFoundation
import Security

/// Authenticates the live process behind a native Chrome-channel connection.
public struct ChromeProcessCodeSignatureValidator: Sendable {
    public typealias Validate = @Sendable (
        _ processIdentifier: pid_t,
        _ processStartIdentity: UInt64,
        _ channel: ChromeChannelIdentity) -> Identity?

    public struct Identity: Equatable, Sendable {
        public let identifier: String
        public let teamIdentifier: String
        public let codeDirectoryHash: Data

        public init(identifier: String, teamIdentifier: String, codeDirectoryHash: Data) {
            self.identifier = identifier
            self.teamIdentifier = teamIdentifier
            self.codeDirectoryHash = codeDirectoryHash
        }
    }

    public let validate: Validate

    public init(validate: @escaping Validate) {
        self.validate = validate
    }

    public static let live = ChromeProcessCodeSignatureValidator { processIdentifier, generation, channel in
        Self.validate(
            processIdentifier: processIdentifier,
            processStartIdentity: generation,
            channel: channel,
            source: .live)
    }
}

extension ChromeProcessCodeSignatureValidator {
    public static let googleChromeTeamIdentifier = "EQHXZ8M8AV"

    struct ValidationSource: Sendable {
        let processStartIdentity: @Sendable (pid_t) -> UInt64?
        let identity: @Sendable (pid_t, String, String) -> Identity?

        static let live = ValidationSource(
            processStartIdentity: SystemIdentityResolver.processStartIdentity,
            identity: { processIdentifier, identifier, teamIdentifier in
                ChromeProcessCodeSignatureValidator.liveIdentity(
                    processIdentifier: processIdentifier,
                    identifier: identifier,
                    teamIdentifier: teamIdentifier)
            })
    }

    static func validate(
        processIdentifier: pid_t,
        processStartIdentity: UInt64,
        channel: ChromeChannelIdentity,
        source: ValidationSource) -> Identity?
    {
        guard processIdentifier > 0,
              processStartIdentity > 0,
              source.processStartIdentity(processIdentifier) == processStartIdentity,
              let identity = source.identity(
                  processIdentifier,
                  channel.bundleIdentifier,
                  self.googleChromeTeamIdentifier),
              identity.identifier == channel.bundleIdentifier,
              identity.teamIdentifier == self.googleChromeTeamIdentifier,
              !identity.codeDirectoryHash.isEmpty,
              source.processStartIdentity(processIdentifier) == processStartIdentity
        else {
            return nil
        }
        return identity
    }

    private static func liveIdentity(
        processIdentifier: pid_t,
        identifier: String,
        teamIdentifier: String) -> Identity?
    {
        let attributes: NSDictionary = [kSecGuestAttributePid: processIdentifier]
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess,
              let code,
              let requirement = self.appleAnchoredRequirement(
                  identifier: identifier,
                  teamIdentifier: teamIdentifier)
        else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode,
              let initial = self.signingInformation(staticCode),
              SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(
                  staticCode,
                  SecCSFlags(rawValue: UInt32(kSecCSDoNotValidateResources)),
                  requirement) == errSecSuccess,
              let final = self.signingInformation(staticCode),
              initial == final
        else {
            return nil
        }
        return initial
    }

    private static func signingInformation(_ staticCode: SecStaticCode) -> Identity? {
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let values = information as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              let teamIdentifier = values[kSecCodeInfoTeamIdentifier as String] as? String,
              let codeDirectoryHash = values[kSecCodeInfoUnique as String] as? Data,
              !codeDirectoryHash.isEmpty
        else {
            return nil
        }
        return Identity(
            identifier: identifier,
            teamIdentifier: teamIdentifier,
            codeDirectoryHash: codeDirectoryHash)
    }

    private static func appleAnchoredRequirement(
        identifier: String,
        teamIdentifier: String) -> SecRequirement?
    {
        guard self.isSafeRequirementIdentifier(identifier),
              self.isSafeRequirementTeamIdentifier(teamIdentifier)
        else {
            return nil
        }
        let source = "identifier \"\(identifier)\" and anchor apple generic and " +
            "certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(source as CFString, SecCSFlags(), &requirement) == errSecSuccess else {
            return nil
        }
        return requirement
    }

    private static func isSafeRequirementIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            self.isASCIILetterOrDigit($0) || ".-_".unicodeScalars.contains($0)
        }
    }

    private static func isSafeRequirementTeamIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy(self.isASCIILetterOrDigit)
    }

    private static func isASCIILetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value) || (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }
}
