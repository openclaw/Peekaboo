import Testing
@testable import PeekabooFoundation

struct SourceProvenanceTests {
    private let exact = "0123456789abcdef0123456789abcdef01234567"

    @Test
    func `exact commit accepts one canonical full object name`() {
        #expect(SourceProvenance.exactCommit(self.exact) == self.exact)
        #expect(SourceProvenance.normalizedCommit(self.exact) == self.exact)
    }

    @Test(arguments: [
        nil,
        "",
        "unknown",
        "0123456789abcdef0123456789abcdef0123456",
        "0123456789abcdef0123456789abcdef012345678",
        "0123456789ABCDEF0123456789ABCDEF01234567",
        "0123456789abcdef0123456789abcdef0123456g",
        "0123456789abcdef0123456789abcdef01234567-dirty",
    ] as [String?])
    func `malformed source stamps remain explicitly unknown`(_ value: String?) {
        #expect(SourceProvenance.exactCommit(value) == nil)
        #expect(SourceProvenance.normalizedCommit(value) == "unknown")
    }
}
