import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Security

public struct PeekabooBridgeAuthenticatedHostIdentity: Codable, Equatable, Sendable {
    public let processIdentifier: pid_t
    public let processStartIdentity: UInt64
    public let signingIdentifier: String
    public let teamIdentifier: String
    public let codeSignatureHash: String
    public let sourceCommit: String
    public let bundleShortVersion: String?
    public let bundleVersion: String?

    public init(
        processIdentifier: pid_t,
        processStartIdentity: UInt64,
        signingIdentifier: String,
        teamIdentifier: String,
        codeSignatureHash: String,
        sourceCommit: String,
        bundleShortVersion: String?,
        bundleVersion: String?)
    {
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.codeSignatureHash = codeSignatureHash
        self.sourceCommit = sourceCommit
        self.bundleShortVersion = bundleShortVersion
        self.bundleVersion = bundleVersion
    }

    @MainActor
    public static func current() -> Self? {
        let processIdentifier = getpid()
        guard let processStartIdentity = SystemIdentityResolver.processStartIdentity(processIdentifier),
              let information = PeekabooBridgeCodeSignatureIdentity
                  .authenticatedCurrentProcessSigningInformation(),
                  let signingIdentifier = information[kSecCodeInfoIdentifier as String] as? String,
                  let teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String,
                  PeekabooBridgeConstants.trustedReleaseTeamIDs.contains(teamIdentifier),
                  let codeSignatureHashData = information[kSecCodeInfoUnique as String] as? Data,
                  let plist = information[kSecCodeInfoPList as String] as? [String: Any],
                  let sourceCommit = SourceProvenance.exactCommit(plist["PeekabooSourceCommit"] as? String),
                  SystemIdentityResolver.processStartIdentity(processIdentifier) == processStartIdentity
        else { return nil }
        return Self(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity,
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier,
            codeSignatureHash: codeSignatureHashData.map { String(format: "%02x", $0) }.joined(),
            sourceCommit: sourceCommit,
            bundleShortVersion: plist["CFBundleShortVersionString"] as? String,
            bundleVersion: plist["CFBundleVersion"] as? String)
    }
}

extension PeekabooBridgeHostIdentity {
    /// Captures the serving process generation and exact signed executable identity once, when
    /// the Bridge server is created. A code-signature hash is preferable to a display version:
    /// deployment can compare it with the installed artifact even across same-version rebuilds.
    @MainActor
    public static func current(bundle: Bundle = .main) -> Self {
        let processIdentifier = getpid()
        let info = bundle.infoDictionary
        return Self(
            processIdentifier: processIdentifier,
            processStartIdentity: SystemIdentityResolver.processStartIdentity(processIdentifier),
            bundleIdentifier: bundle.bundleIdentifier,
            bundleShortVersion: info?["CFBundleShortVersionString"] as? String,
            bundleVersion: info?["CFBundleVersion"] as? String,
            codeSignatureHash: Self.currentCodeSignatureHash(),
            sourceCommit: SourceProvenance.exactCommit(info?["PeekabooSourceCommit"] as? String))
    }

    private static func currentCodeSignatureHash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let values = information as? [String: Any],
              let hash = values[kSecCodeInfoUnique as String] as? Data,
              !hash.isEmpty
        else {
            return nil
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
