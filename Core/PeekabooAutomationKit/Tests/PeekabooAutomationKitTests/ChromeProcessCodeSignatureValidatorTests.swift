import Darwin
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct ChromeProcessCodeSignatureValidatorTests {
    @Test
    func `official Google identity with stable process generation validates`() {
        let source = Self.source(identity: Self.identity())

        #expect(ChromeProcessCodeSignatureValidator.validate(
            processIdentifier: 71,
            processStartIdentity: 9071,
            channel: .stable,
            source: source) == Self.identity())
    }

    @Test(arguments: [
        ChromeProcessCodeSignatureValidator.Identity(
            identifier: "com.google.Chrome",
            teamIdentifier: "OTHERTEAM1",
            codeDirectoryHash: Data([1])),
        ChromeProcessCodeSignatureValidator.Identity(
            identifier: "com.google.Chrome.canary",
            teamIdentifier: ChromeProcessCodeSignatureValidator.googleChromeTeamIdentifier,
            codeDirectoryHash: Data([1])),
        ChromeProcessCodeSignatureValidator.Identity(
            identifier: "com.google.Chrome",
            teamIdentifier: ChromeProcessCodeSignatureValidator.googleChromeTeamIdentifier,
            codeDirectoryHash: Data()),
    ])
    func `wrong team identifier or empty code hash refuses`(
        identity: ChromeProcessCodeSignatureValidator.Identity)
    {
        #expect(ChromeProcessCodeSignatureValidator.validate(
            processIdentifier: 71,
            processStartIdentity: 9071,
            channel: .stable,
            source: Self.source(identity: identity)) == nil)
    }

    @Test
    func `unsigned or generation changing process refuses`() {
        #expect(ChromeProcessCodeSignatureValidator.validate(
            processIdentifier: 71,
            processStartIdentity: 9071,
            channel: .stable,
            source: Self.source(identity: nil)) == nil)

        let generations = SignatureGenerationBox([9071, 9072])
        let source = ChromeProcessCodeSignatureValidator.ValidationSource(
            processStartIdentity: { _ in generations.next() },
            identity: { _, _, _ in Self.identity() })
        #expect(ChromeProcessCodeSignatureValidator.validate(
            processIdentifier: 71,
            processStartIdentity: 9071,
            channel: .stable,
            source: source) == nil)
    }

    private static func source(identity: ChromeProcessCodeSignatureValidator.Identity?)
        -> ChromeProcessCodeSignatureValidator.ValidationSource
    {
        .init(
            processStartIdentity: { _ in 9071 },
            identity: { _, _, _ in identity })
    }

    private static func identity() -> ChromeProcessCodeSignatureValidator.Identity {
        .init(
            identifier: "com.google.Chrome",
            teamIdentifier: ChromeProcessCodeSignatureValidator.googleChromeTeamIdentifier,
            codeDirectoryHash: Data([1]))
    }
}

private final class SignatureGenerationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]

    init(_ values: [UInt64]) {
        self.values = values
    }

    func next() -> UInt64? {
        self.lock.withLock {
            guard !self.values.isEmpty else { return nil }
            return self.values.removeFirst()
        }
    }
}
