import PeekabooBridge
import Testing
@testable import PeekabooCLI
@testable import PeekabooCore

@Suite(.tags(.safe))
@MainActor
struct BrowserSessionTransportRuntimeTests {
    @Test
    func `runtime injects browser session transport only for exact negotiated capability`() throws {
        let client = PeekabooBridgeClient(
            socketPath: "/private/tmp/peekaboo-browser-session-transport-test.sock",
            requestTimeoutSec: 0.1
        )
        let supported = Self.handshake()
        let supportedServices = RuntimeHostResolver.remoteServices(
            client: client,
            handshake: supported,
            options: CommandRuntimeOptions()
        )
        let supportedBrowser = try #require(supportedServices.browser as? RemoteBrowserMCPClient)
        #expect(supportedBrowser.hasScopedSessionTransport)

        for unsupported in [
            Self.handshake(minor: 37),
            Self.handshake(hostKind: .gui),
            Self.handshake(includeCapability: false),
            Self.handshake(omitting: .browserSessionControl),
            Self.handshake(disabling: .browserSessionBootstrap),
        ] {
            let services = RuntimeHostResolver.remoteServices(
                client: client,
                handshake: unsupported,
                options: CommandRuntimeOptions()
            )
            let browser = try #require(services.browser as? RemoteBrowserMCPClient)
            #expect(!browser.hasScopedSessionTransport)
        }
    }

    @Test
    func `capability policy requires every scoped browser operation enabled`() {
        #expect(BridgeCapabilityPolicy.supportsBrowserConnectionHandoff(for: Self.handshake()))
        #expect(!BridgeCapabilityPolicy.supportsBrowserConnectionHandoff(
            for: Self.handshake(disabling: .browserExecute)
        ))
    }

    private static let operations: [PeekabooBridgeOperation] = [
        .browserStatus,
        .browserConnect,
        .browserExecute,
        .browserSessionBootstrap,
        .browserSessionControl,
    ]

    private static func handshake(
        minor: Int = 38,
        hostKind: PeekabooBridgeHostKind = .onDemand,
        includeCapability: Bool = true,
        omitting operationToOmit: PeekabooBridgeOperation? = nil,
        disabling disabledOperation: PeekabooBridgeOperation? = nil
    ) -> PeekabooBridgeHandshakeResponse {
        let supported = self.operations.filter { $0 != operationToOmit }
        let enabled = supported.filter { $0 != disabledOperation }
        return PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: minor),
            hostKind: hostKind,
            build: nil,
            supportedOperations: supported,
            enabledOperations: enabled,
            hostCapabilities: includeCapability ? [PeekabooBridgeHostCapability.browserConnectionHandoff] : []
        )
    }
}
