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
            probeWebSocket: { webSocketURL, browserID, _, onDispatch in
                onDispatch()
                #expect(webSocketURL.absoluteString ==
                    "ws://127.0.0.1:9222/devtools/browser/browser-a")
                #expect(browserID == "browser-a")
                return Self.version()
            })

        #expect(endpoint.webSocketDebuggerURL == "ws://127.0.0.1:9222/devtools/browser/browser-a")
        #expect(endpoint.listenerIdentity == Self.listener(socket: 100))
        #expect(inspections.remaining == 0)
    }

    @Test
    func `DevTools authority is reserved before permission bearing WebSocket probe`() async throws {
        let order = EndpointReservationOrder()
        let inspections = ListenerInspections([
            Self.listener(socket: 100),
            Self.listener(socket: 100),
        ])

        _ = try await BrowserMCPChannelEndpointResolver.resolveEndpoint(
            target: Self.target(),
            activePortURL: URL(fileURLWithPath: "/fixture/DevToolsActivePort"),
            readActivePort: { _ in Self.activePortData() },
            inspectListener: { _, _, _ in try inspections.next() },
            probeWebSocket: { _, _, _, onDispatch in
                #expect(order.wasReserved)
                onDispatch()
                return Self.version()
            },
            reserveAuthority: { reservation in
                #expect(reservation.browserID == "browser-a")
                #expect(reservation.browserURL == "http://127.0.0.1:9222/")
                order.recordReservation()
            })

        #expect(order.wasReserved)
    }

    @Test
    func `same port listener reopen is refused during later revalidation`() async throws {
        let initialInspections = ListenerInspections([
            Self.listener(socket: 100),
            Self.listener(socket: 100),
        ])
        let endpoint = try await BrowserMCPChannelEndpointResolver.resolveEndpoint(
            target: Self.target(),
            activePortURL: URL(fileURLWithPath: "/fixture/DevToolsActivePort"),
            readActivePort: { _ in Self.activePortData() },
            inspectListener: { _, _, _ in try initialInspections.next() },
            probeWebSocket: { _, _, _, onDispatch in
                onDispatch()
                return Self.version()
            })

        #expect(throws: BrowserMCPConnectionError.self) {
            try BrowserMCPChannelEndpointResolver.revalidateEndpoint(
                target: Self.target(),
                expected: endpoint,
                activePortURL: URL(fileURLWithPath: "/fixture/DevToolsActivePort"),
                readActivePort: { _ in Self.activePortData() },
                inspectListener: { _, _, _ in Self.listener(socket: 200) })
        }
    }

    @Test
    func `listener handoff during Browser getVersion is refused`() async {
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
                probeWebSocket: { _, _, _, onDispatch in
                    onDispatch()
                    return Self.version()
                })
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
            probeWebSocket: { webSocketURL, browserID, _, onDispatch in
                onDispatch()
                #expect(webSocketURL.absoluteString == "ws://[::1]:9222/devtools/browser/browser-a")
                #expect(browserID == "browser-a")
                return Self.version()
            })

        #expect(endpoint.browserURL == "http://[::1]:9222/")
    }

    @Test
    func `PID reuse during Browser getVersion is refused`() async {
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
                probeWebSocket: { _, _, _, onDispatch in
                    onDispatch()
                    return Self.version()
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
        let probes = InvocationCount()

        await #expect(throws: BrowserMCPConnectionError.self) {
            _ = try await BrowserMCPChannelEndpointResolver.resolveEndpoint(
                target: Self.target(),
                activePortURL: URL(fileURLWithPath: "/fixture/DevToolsActivePort"),
                readActivePort: { _ in Self.activePortData() },
                inspectListener: { _, _, _ in wrongListener },
                probeWebSocket: { _, _, _, _ in
                    probes.increment()
                    return Self.version()
                })
        }
        #expect(probes.value == 0)
    }

    @Test
    func `malformed active port records fail before listener or WebSocket access`() async {
        let malformedRecords = [
            Data(),
            Data("0\n/devtools/browser/browser-a".utf8),
            Data("70000\n/devtools/browser/browser-a".utf8),
            Data("9222\n/devtools/page/browser-a".utf8),
            Data("9222\n/devtools/browser/browser/a".utf8),
            Data("9222\n/devtools/browser/browser-a?query".utf8),
            Data("9222\n/devtools/browser/browser%2Fa".utf8),
            Data("9222\n/devtools/browser/browser-a\nextra".utf8),
            Data("9222\n/devtools/browser/browser-a\0".utf8),
        ]

        for record in malformedRecords {
            let listenerInspections = InvocationCount()
            let probes = InvocationCount()
            do {
                _ = try await BrowserMCPChannelEndpointResolver.resolveEndpoint(
                    target: Self.target(),
                    activePortURL: URL(fileURLWithPath: "/fixture/DevToolsActivePort"),
                    readActivePort: { _ in record },
                    inspectListener: { _, _, _ in
                        listenerInspections.increment()
                        return Self.listener(socket: 100)
                    },
                    probeWebSocket: { _, _, _, _ in
                        probes.increment()
                        return Self.version()
                    })
                Issue.record("Expected malformed DevToolsActivePort to be refused")
            } catch let error as BrowserMCPConnectionError {
                #expect(error.localizedDescription.contains("running stable Chrome channel"))
                #expect(!error.localizedDescription.contains("Invalid browser_url"))
            } catch {
                Issue.record("Expected a channel-specific connection error, got \(error)")
            }
            #expect(listenerInspections.value == 0)
            #expect(probes.value == 0)
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

    private static func version() -> BrowserMCPDevToolsVersion {
        .init(
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
    }
}

private final class InvocationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        self.lock.withLock { self.count }
    }

    func increment() {
        self.lock.withLock { self.count += 1 }
    }
}

private final class EndpointReservationOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var reserved = false

    var wasReserved: Bool {
        self.lock.withLock { self.reserved }
    }

    func recordReservation() {
        self.lock.withLock { self.reserved = true }
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
