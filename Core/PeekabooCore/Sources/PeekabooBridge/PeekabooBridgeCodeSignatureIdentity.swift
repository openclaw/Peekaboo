import Darwin
import Foundation
import PeekabooAutomationKit
import Security

@_silgen_name("csops")
private func peekaboo_csops(
    _ processIdentifier: pid_t,
    _ operation: UInt32,
    _ userAddress: UnsafeMutableRawPointer?,
    _ userSize: Int) -> Int32

@_silgen_name("csops_audittoken")
private func peekaboo_csops_audittoken(
    _ processIdentifier: pid_t,
    _ operation: UInt32,
    _ userAddress: UnsafeMutableRawPointer?,
    _ userSize: Int,
    _ auditToken: UnsafeMutablePointer<audit_token_t>?) -> Int32

enum PeekabooBridgeCodeSignatureIdentity {
    struct ValidatedSigningIdentity: Equatable, Sendable {
        let identifier: String
        let teamIdentifier: String
        let codeDirectoryHash: Data
    }

    typealias AuditTokenCDHashSystemCall = (
        pid_t,
        UInt32,
        UnsafeMutableRawPointer?,
        Int,
        UnsafeMutablePointer<audit_token_t>?) -> Int32

    typealias StaticSigningInformationProvider =
        (PeekabooBridgePeerAuditIdentity) -> [String: Any]?

    typealias AnchoredSignatureValidationProvider =
        (PeekabooBridgePeerAuditIdentity) -> ValidatedSigningIdentity?

    private static let codeDirectoryHashOperation: UInt32 = 5
    private static let codeDirectoryHashByteCount = 20

    /// Returns the kernel's code-directory hash for this process's live executable.
    ///
    /// The PID-only `csops` form is safe here because the caller can only request its own PID. Peer identities must use
    /// the audit-token overload below so PID reuse cannot redirect the lookup.
    static func codeSignatureHash(processIdentifier: pid_t) -> String? {
        guard processIdentifier == getpid() else { return nil }
        var hash = [UInt8](repeating: 0, count: self.codeDirectoryHashByteCount)
        let result = hash.withUnsafeMutableBytes { buffer in
            peekaboo_csops(
                processIdentifier,
                self.codeDirectoryHashOperation,
                buffer.baseAddress,
                buffer.count)
        }
        guard result == 0, hash.contains(where: { $0 != 0 }) else { return nil }
        return self.hexString(for: Data(hash))
    }

    /// Returns Apple-anchored signing metadata for the live current process, bracketed by
    /// its kernel CDHash and process generation.
    static func authenticatedCurrentProcessSigningInformation() -> [String: Any]? {
        let processIdentifier = getpid()
        guard let processStartIdentity = SystemIdentityResolver.processStartIdentity(processIdentifier),
              let liveHashBefore = self.codeSignatureHash(processIdentifier: processIdentifier)
        else { return nil }

        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess,
              let code
        else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode,
              let initialInformation = self.signingInformation(staticCode),
              let identifier = initialInformation[kSecCodeInfoIdentifier as String] as? String,
              let teamIdentifier = initialInformation[kSecCodeInfoTeamIdentifier as String] as? String,
              let initialHash = initialInformation[kSecCodeInfoUnique as String] as? Data,
              self.hexString(for: initialHash) == liveHashBefore,
              let requirement = self.appleAnchoredRequirement(
                  identifier: identifier,
                  teamIdentifier: teamIdentifier),
              SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(
                  staticCode,
                  SecCSFlags(rawValue: UInt32(kSecCSDoNotValidateResources)),
                  requirement) == errSecSuccess,
              let finalInformation = self.signingInformation(staticCode),
              finalInformation[kSecCodeInfoIdentifier as String] as? String == identifier,
              finalInformation[kSecCodeInfoTeamIdentifier as String] as? String == teamIdentifier,
              let finalHash = finalInformation[kSecCodeInfoUnique as String] as? Data,
              self.hexString(for: finalHash) == liveHashBefore,
              self.codeSignatureHash(processIdentifier: processIdentifier) == liveHashBefore,
              SystemIdentityResolver.processStartIdentity(processIdentifier) == processStartIdentity
        else { return nil }
        return finalInformation
    }

    /// Returns the kernel CDHash for one caller-owned, unreaped process generation.
    ///
    /// Unlike a socket peer, a freshly spawned child has no peer audit token. Its parent keeps
    /// the generation allocated through `waitpid`, and this helper brackets the PID-only kernel
    /// query with the exact process-start identity so callers cannot accept a different process.
    static func codeSignatureHash(
        processIdentifier: pid_t,
        expectedProcessStartIdentity: UInt64) -> String?
    {
        guard processIdentifier > 0,
              SystemIdentityResolver.processStartIdentity(processIdentifier) == expectedProcessStartIdentity
        else { return nil }
        var hash = [UInt8](repeating: 0, count: self.codeDirectoryHashByteCount)
        let result = hash.withUnsafeMutableBytes { buffer in
            peekaboo_csops(
                processIdentifier,
                self.codeDirectoryHashOperation,
                buffer.baseAddress,
                buffer.count)
        }
        guard result == 0,
              hash.contains(where: { $0 != 0 }),
              SystemIdentityResolver.processStartIdentity(processIdentifier) == expectedProcessStartIdentity
        else { return nil }
        return self.hexString(for: Data(hash))
    }

    /// Returns the validated static CDHash of one exact signed executable path.
    static func codeSignatureHash(executablePath: String) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            URL(fileURLWithPath: executablePath) as CFURL,
            SecCSFlags(),
            &staticCode) == errSecSuccess,
            let staticCode,
            SecStaticCodeCheckValidity(staticCode, SecCSFlags(), nil) == errSecSuccess,
            let information = self.signingInformation(staticCode),
            let hash = information[kSecCodeInfoUnique as String] as? Data,
            hash.count == self.codeDirectoryHashByteCount
        else { return nil }
        return self.hexString(for: hash)
    }

    /// Returns the kernel's code-directory hash for the exact process generation named by a socket peer audit token.
    static func codeSignatureHash(
        auditIdentity: PeekabooBridgePeerAuditIdentity,
        systemCall: AuditTokenCDHashSystemCall = peekaboo_csops_audittoken) -> String?
    {
        self.liveCodeSignatureHash(auditIdentity: auditIdentity, systemCall: systemCall)
            .map(self.hexString(for:))
    }

    /// Returns static signature metadata only after binding it to a valid, Apple-anchored live signature and the
    /// kernel CDHash on both sides of the lookup.
    ///
    /// Security.framework obtains identifiers and entitlements from the executable on disk. A writable executable path
    /// can change after launch, so that metadata is authorization-safe only when its exact CDHash matches the peer's
    /// audit-token-bound live executable before and after the lookup.
    static func signingInformation(
        auditIdentity: PeekabooBridgePeerAuditIdentity,
        systemCall: AuditTokenCDHashSystemCall = peekaboo_csops_audittoken,
        staticSigningInformationProvider: StaticSigningInformationProvider =
            PeekabooBridgeCodeSignatureIdentity.unvalidatedStaticSigningInformation,
        anchoredSignatureValidationProvider: AnchoredSignatureValidationProvider =
            PeekabooBridgeCodeSignatureIdentity.validatedAppleAnchoredSigningIdentity) -> [String: Any]?
    {
        guard let liveHashBefore = self.liveCodeSignatureHash(
            auditIdentity: auditIdentity,
            systemCall: systemCall),
            var information = staticSigningInformationProvider(auditIdentity),
            let staticHash = information[kSecCodeInfoUnique as String] as? Data,
            staticHash.count == self.codeDirectoryHashByteCount,
            let staticIdentifier = information[kSecCodeInfoIdentifier as String] as? String,
            let staticTeamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String
        else {
            return nil
        }

        // Do not invoke the comparatively expensive trust validator for metadata already known to name a different
        // executable, but retain the second audit-token lookup so every usable static result is race checked.
        let validatedIdentity: ValidatedSigningIdentity? = if staticHash == liveHashBefore {
            anchoredSignatureValidationProvider(auditIdentity)
        } else {
            nil
        }
        guard let liveHashAfter = self.liveCodeSignatureHash(
            auditIdentity: auditIdentity,
            systemCall: systemCall),
            liveHashBefore == liveHashAfter,
            let validatedIdentity,
            validatedIdentity.identifier == staticIdentifier,
            validatedIdentity.teamIdentifier == staticTeamIdentifier,
            validatedIdentity.codeDirectoryHash == staticHash,
            validatedIdentity.codeDirectoryHash == liveHashAfter
        else {
            return nil
        }

        // Downstream identity construction consumes only the values independently bound to the live peer.
        information[kSecCodeInfoIdentifier as String] = validatedIdentity.identifier
        information[kSecCodeInfoTeamIdentifier as String] = validatedIdentity.teamIdentifier
        information[kSecCodeInfoUnique as String] = liveHashBefore
        return information
    }

    private static func liveCodeSignatureHash(
        auditIdentity: PeekabooBridgePeerAuditIdentity,
        systemCall: AuditTokenCDHashSystemCall) -> Data?
    {
        guard audit_token_to_pid(auditIdentity.token) == auditIdentity.processIdentifier,
              audit_token_to_pidversion(auditIdentity.token) == auditIdentity.processIdentifierVersion,
              audit_token_to_euid(auditIdentity.token) == auditIdentity.effectiveUserIdentifier,
              auditIdentity.processIdentifier > 0
        else {
            return nil
        }

        var token = auditIdentity.token
        var hash = [UInt8](repeating: 0, count: self.codeDirectoryHashByteCount)
        let result = hash.withUnsafeMutableBytes { buffer in
            withUnsafeMutablePointer(to: &token) { tokenPointer in
                systemCall(
                    auditIdentity.processIdentifier,
                    self.codeDirectoryHashOperation,
                    buffer.baseAddress,
                    buffer.count,
                    tokenPointer)
            }
        }
        guard result == 0, hash.contains(where: { $0 != 0 }) else { return nil }
        return Data(hash)
    }

    private static func unvalidatedStaticSigningInformation(
        auditIdentity: PeekabooBridgePeerAuditIdentity) -> [String: Any]?
    {
        guard let (_, staticCode) = self.codePair(auditIdentity: auditIdentity),
              let values = self.signingInformation(staticCode)
        else {
            return nil
        }
        return values
    }

    /// Validates the exact live peer and its on-disk code against a certificate-backed Apple requirement.
    ///
    /// `anchor apple generic` admits Apple-issued Developer ID and Apple Development chains. Requiring the signed
    /// identifier and leaf certificate OU makes the Team ID an authenticated certificate claim rather than trusting
    /// the independently readable CodeDirectory metadata. The deliberately narrow character sets keep untrusted
    /// metadata from changing the requirement grammar.
    private static func validatedAppleAnchoredSigningIdentity(
        auditIdentity: PeekabooBridgePeerAuditIdentity) -> ValidatedSigningIdentity?
    {
        guard let (code, staticCode) = self.codePair(auditIdentity: auditIdentity),
              let initialInformation = self.signingInformation(staticCode),
              let identifier = initialInformation[kSecCodeInfoIdentifier as String] as? String,
              let teamIdentifier = initialInformation[kSecCodeInfoTeamIdentifier as String] as? String,
              let requirement = self.appleAnchoredRequirement(
                  identifier: identifier,
                  teamIdentifier: teamIdentifier),
              SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess,
              // Peer authorization needs the signed executable identity, not a per-request bundle resource scan.
              SecStaticCodeCheckValidity(
                  staticCode,
                  SecCSFlags(rawValue: UInt32(kSecCSDoNotValidateResources)),
                  requirement) == errSecSuccess,
              let staticInformation = self.signingInformation(staticCode),
              staticInformation[kSecCodeInfoIdentifier as String] as? String == identifier,
              staticInformation[kSecCodeInfoTeamIdentifier as String] as? String == teamIdentifier,
              let staticHash = staticInformation[kSecCodeInfoUnique as String] as? Data,
              staticHash.count == self.codeDirectoryHashByteCount
        else {
            return nil
        }

        return ValidatedSigningIdentity(
            identifier: identifier,
            teamIdentifier: teamIdentifier,
            codeDirectoryHash: staticHash)
    }

    private static func codePair(
        auditIdentity: PeekabooBridgePeerAuditIdentity) -> (SecCode, SecStaticCode)?
    {
        let attributes: NSDictionary = [kSecGuestAttributeAudit: auditIdentity.tokenData]
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess,
              let code
        else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }

        return (code, staticCode)
    }

    private static func signingInformation(_ staticCode: SecStaticCode) -> [String: Any]? {
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let values = information as? [String: Any]
        else {
            return nil
        }
        return values
    }

    static func appleAnchoredRequirement(
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

    private static func isSafeRequirementIdentifier(_ identifier: String) -> Bool {
        !identifier.isEmpty && identifier.unicodeScalars.allSatisfy {
            self.isASCIILetterOrDigit($0) || ".-_".unicodeScalars.contains($0)
        }
    }

    private static func isSafeRequirementTeamIdentifier(_ teamIdentifier: String) -> Bool {
        !teamIdentifier.isEmpty && teamIdentifier.unicodeScalars.allSatisfy {
            self.isASCIILetterOrDigit($0)
        }
    }

    private static func isASCIILetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value) || (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    private static func hexString(for hash: Data) -> String {
        hash.map { String(format: "%02x", $0) }.joined()
    }
}
