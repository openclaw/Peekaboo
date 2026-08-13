import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Security

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
