import Foundation
import PeekabooAutomationKit
import Testing
@testable import PeekabooAgentRuntime

struct BrowserMCPChannelEndpointResolverTests {
    @Test(arguments: [DarwinLoopbackAddressFamily.ipv4, .ipv6])
    func `native discovery reserves listener identity without opening Chrome`(family: DarwinLoopbackAddressFamily)
        async throws
    {
        let attempt = BrowserMCPConnectionAttempt.standalone()
        let endpoint = try await BrowserMCPChannelEndpointResolver.resolveEndpoint(
            target: Self.target(),
            attempt: attempt,
            activePortURL: URL(fileURLWithPath: "/fixture/DevToolsActivePort"),
            readActivePort: { _ in Self.activePortData() },
            inspectListener: { _, _, _ in Self.listener(socket: 100, family: family) },
            reserveAuthority: { reservation in
                #expect(reservation.browserID == "browser-a")
                #expect(reservation.browserURL == "http://\(family.httpHost):9222/")
            })

        #expect(endpoint.webSocketDebuggerURL == "ws://\(family.httpHost):9222/devtools/browser/browser-a")
        #expect(endpoint.listenerIdentity == Self.listener(socket: 100, family: family))
        #expect(endpoint.browserVersion == nil)
        #expect(endpoint.protocolVersion == nil)
        #expect(!attempt.state.didStartAnyDispatch)
    }

    @Test
    func `listener replacement after provider approval fails revalidation`() async throws {
        let endpoint = try await BrowserMCPChannelEndpointResolver.resolveEndpoint(
            target: Self.target(),
            activePortURL: URL(fileURLWithPath: "/fixture/DevToolsActivePort"),
            readActivePort: { _ in Self.activePortData() },
            inspectListener: { _, _, _ in Self.listener(socket: 100) })

        #expect(throws: BrowserMCPConnectionError.self) {
            try BrowserMCPChannelEndpointResolver.revalidateEndpoint(
                target: Self.target(),
                expected: endpoint,
                activePortURL: URL(fileURLWithPath: "/fixture/DevToolsActivePort"),
                readActivePort: { _ in Self.activePortData() },
                inspectListener: { _, _, _ in Self.listener(socket: 200) })
        }
        #expect(throws: BrowserMCPConnectionError.self) {
            try BrowserMCPChannelEndpointResolver.revalidateEndpoint(
                target: Self.target(),
                expected: endpoint,
                activePortURL: URL(fileURLWithPath: "/fixture/DevToolsActivePort"),
                readActivePort: { _ in Self.activePortData() },
                inspectListener: { _, _, _ in
                    throw DarwinProcessLoopbackListenerInspectionError.processGenerationChanged(81)
                })
        }
    }

    @Test
    func `listener inspection cannot substitute another process identity`() async {
        let wrongListener = DarwinProcessLoopbackListenerIdentity(
            processIdentifier: 82,
            processStartIdentity: 5082,
            addressFamily: .ipv4,
            port: 9222,
            kernelSocketAddress: 100,
            kernelProtocolControlBlock: 101,
            kernelGeneration: 102)
        await #expect(throws: BrowserMCPConnectionError.self) {
            _ = try await BrowserMCPChannelEndpointResolver.resolveEndpoint(
                target: Self.target(),
                activePortURL: URL(fileURLWithPath: "/fixture/DevToolsActivePort"),
                readActivePort: { _ in Self.activePortData() },
                inspectListener: { _, _, _ in wrongListener })
        }
    }

    @Test(arguments: [
        "", "0\n/devtools/browser/a", "70000\n/devtools/browser/a", "9222\n/devtools/page/a",
        "9222\n/devtools/browser/a/b", "9222\n/devtools/browser/a?q", "9222\n/devtools/browser/a%2Fb",
        "9222\n/devtools/browser/a\nextra", "9222\n/devtools/browser/a\0",
    ])
    func `malformed active port fails before listener inspection`(record: String) async {
        await #expect(throws: BrowserMCPConnectionError.self) {
            _ = try await BrowserMCPChannelEndpointResolver.resolveEndpoint(
                target: Self.target(),
                activePortURL: URL(fileURLWithPath: "/fixture/DevToolsActivePort"),
                readActivePort: { _ in Data(record.utf8) },
                inspectListener: { _, _, _ in
                    Issue.record("Malformed authority must not reach listener inspection")
                    return Self.listener(socket: 100)
                })
        }
    }

    @Test
    func `channel profile paths are fixed and cannot follow a headless custom profile`() {
        let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
        let expected: [BrowserMCPChannel: String] = [
            .stable: "/Users/fixture/Library/Application Support/Google/Chrome/DevToolsActivePort",
            .beta: "/Users/fixture/Library/Application Support/Google/Chrome Beta/DevToolsActivePort",
            .dev: "/Users/fixture/Library/Application Support/Google/Chrome Dev/DevToolsActivePort",
            .canary: "/Users/fixture/Library/Application Support/Google/Chrome Canary/DevToolsActivePort",
        ]

        for (channel, path) in expected {
            #expect(BrowserMCPChannelEndpointResolver.activePortURL(
                channel: channel,
                homeDirectory: home).path == path)
        }
    }

    private static func target() -> BrowserMCPChannelProcessTarget {
        .init(
            channel: .stable,
            processIdentifier: 81,
            processStartIdentity: 5081,
            bundleIdentifier: "com.google.Chrome")
    }

    private static func activePortData() -> Data {
        Data("9222\n/devtools/browser/browser-a".utf8)
    }

    private static func listener(
        socket: UInt64,
        family: DarwinLoopbackAddressFamily = .ipv4) -> DarwinProcessLoopbackListenerIdentity
    {
        .init(
            processIdentifier: 81,
            processStartIdentity: 5081,
            addressFamily: family,
            port: 9222,
            kernelSocketAddress: socket,
            kernelProtocolControlBlock: socket + 1,
            kernelGeneration: socket + 2)
    }
}
