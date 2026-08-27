import Foundation

enum PeekabooBridgeBrowserCapabilityNamespaceNegotiation {
    struct HostSupport {
        let hostKind: PeekabooBridgeHostKind
        let maximumProtocolVersion: PeekabooBridgeProtocolVersion
        let allowedOperations: Set<PeekabooBridgeOperation>
        let supportsBrowserCapabilityNamespaces: Bool
        let supportsNativeBrowserWindowBinding: Bool
    }

    struct SessionSupport {
        let host: HostSupport
        let usesAttestedOperationReceipts: Bool
        let clientCapabilities: Set<String>
    }

    static func hostCanDeclareCapabilities(_ support: HostSupport) -> Bool {
        support.hostKind == .onDemand &&
            support.maximumProtocolVersion >= PeekabooBridgeConstants.browserCapabilityNamespaceVersion &&
            support.supportsBrowserCapabilityNamespaces &&
            support.supportsNativeBrowserWindowBinding &&
            PeekabooBridgeOperation.browserCapabilityNamespaceOperations.isSubset(of: support.allowedOperations)
    }

    static func sessionCanNegotiateCapabilities(_ support: SessionSupport) -> Bool {
        support.usesAttestedOperationReceipts &&
            self.hostCanDeclareCapabilities(support.host) &&
            support.clientCapabilities.contains(PeekabooBridgeClientCapability.browserCapabilityNamespaces) &&
            support.clientCapabilities.contains(PeekabooBridgeClientCapability.nativeBrowserWindowBinding)
    }
}
