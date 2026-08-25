import Foundation
import PeekabooAutomationKit
import Testing
@testable import PeekabooAgentRuntime

struct BrowserMCPChannelEndpointResolverTests {
    @Test
    func `stable active port and unchanged native listener resolve an exact WebSocket`() async throws {
        let inspections = ListenerInspections([
            Self.listener(socket: 100),
            Self.listener(socket: 100),
        ])
        let target = Self.target()

        let endpoint = try await BrowserMCPChannelEndpointResolver.resolveEndpoint(
            target: target,
            activePortURL: URL(fileURLWithPath: "/fixture/DevToolsActivePort"),
            readActivePort: { _ in Self.activePortData() },
            inspectListener: { _, _, _ in try inspections.next() },
            resolveDevToolsEndpoint: { browserURL in
                #expect(browserURL == "http://127.0.0.1:9222")
                return Self.endpoint()
            })

        #expect(endpoint.webSocketDebuggerURL == "ws://127.0.0.1:9222/devtools/browser/browser-a")
        #expect(inspections.remaining == 0)
    }

    @Test
    func `listener handoff during JSON version is refused`() async {
        let inspections = ListenerInspections([
            Self.listener(socket: 100),
            Self.listener(socket: 200),
        ])

        await #expect(throws: BrowserMCPConnectionError.self) {
            _ = try await BrowserMCPChannelEndpointResolver.resolveEndpoint(
                target: Self.target(),
                activePortURL: URL(fileURLWithPath: "/fixture/DevToolsActivePort"),
                readActivePort: { _ in Self.activePortData() },
                inspectListener: { _, _, _ in try inspections.next() },
                resolveDevToolsEndpoint: { _ in Self.endpoint() })
        }
    }

    @Test
    func `IPv6 ownership cannot be silently routed through IPv4`() async throws {
        let inspections = ListenerInspections([
            Self.listener(socket: 100, family: .ipv6),
            Self.listener(socket: 100, family: .ipv6),
        ])

        let endpoint = try await BrowserMCPChannelEndpointResolver.resolveEndpoint(
            target: Self.target(),
            activePortURL: URL(fileURLWithPath: "/fixture/DevToolsActivePort"),
            readActivePort: { _ in Self.activePortData() },
            inspectListener: { _, _, _ in try inspections.next() },
            resolveDevToolsEndpoint: { browserURL in
                #expect(browserURL == "http://[::1]:9222")
                return .init(
                    browserURL: "http://[::1]:9222/",
                    webSocketDebuggerURL: "ws://[::1]:9222/devtools/browser/browser-a",
                    browserID: "browser-a",
                    browserVersion: "Chrome/151.0",
                    protocolVersion: "1.3")
            })

        #expect(endpoint.browserURL == "http://[::1]:9222/")
    }

    @Test
    func `PID reuse during JSON version is refused`() async {
        let inspections = ListenerInspections([
            .success(Self.listener(socket: 100)),
            .failure(DarwinProcessLoopbackListenerInspectionError.processGenerationChanged(81)),
        ])

        await #expect(throws: BrowserMCPConnectionError.self) {
            _ = try await BrowserMCPChannelEndpointResolver.resolveEndpoint(
                target: Self.target(),
                activePortURL: URL(fileURLWithPath: "/fixture/DevToolsActivePort"),
                readActivePort: { _ in Self.activePortData() },
                inspectListener: { _, _, _ in try inspections.next() },
                resolveDevToolsEndpoint: { _ in Self.endpoint() })
        }
    }

    @Test
    func `active port browser ID must agree with JSON version`() async {
        await #expect(throws: BrowserMCPConnectionError.invalidEndpoint(
            "DevToolsActivePort and /json/version reported different browser identities"))
        {
            _ = try await BrowserMCPChannelEndpointResolver.resolveEndpoint(
                target: Self.target(),
                activePortURL: URL(fileURLWithPath: "/fixture/DevToolsActivePort"),
                readActivePort: { _ in Self.activePortData() },
                inspectListener: { _, _, _ in Self.listener(socket: 100) },
                resolveDevToolsEndpoint: { _ in Self.endpoint(browserID: "browser-b") })
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

    private static func endpoint(browserID: String = "browser-a") -> BrowserMCPDevToolsEndpoint {
        .init(
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/\(browserID)",
            browserID: browserID,
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
    }
}

private final class ListenerInspections: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Result<DarwinProcessLoopbackListenerIdentity, any Error>]

    init(_ values: [DarwinProcessLoopbackListenerIdentity]) {
        self.values = values.map(Result.success)
    }

    init(_ values: [Result<DarwinProcessLoopbackListenerIdentity, any Error>]) {
        self.values = values
    }

    var remaining: Int {
        self.lock.withLock { self.values.count }
    }

    func next() throws -> DarwinProcessLoopbackListenerIdentity {
        try self.lock.withLock {
            try self.values.removeFirst().get()
        }
    }
}
