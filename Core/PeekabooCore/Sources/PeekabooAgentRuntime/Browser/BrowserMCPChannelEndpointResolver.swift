import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

struct BrowserMCPChannelProcessTarget: Sendable, Equatable {
    let channel: BrowserMCPChannel
    let processIdentifier: Int32
    let processStartIdentity: UInt64
    let bundleIdentifier: String
}

struct BrowserMCPChannelEndpointReservation: Sendable, Equatable {
    let browserURL: String
    let webSocketDebuggerURL: String
    let browserID: String
}

private struct BrowserMCPChannelEndpointAuthority: Sendable, Equatable {
    let browserURL: String
    let webSocketDebuggerURL: String
    let browserID: String
    let listener: DarwinProcessLoopbackListenerIdentity
}

struct BrowserMCPChannelEndpointResolver: Sendable {
    typealias Resolve = @Sendable (BrowserMCPChannelProcessTarget) async throws -> BrowserMCPDevToolsEndpoint
    typealias ResolveInitial = @Sendable (
        BrowserMCPChannelProcessTarget,
        BrowserMCPConnectionAttempt,
        (@MainActor @Sendable (BrowserMCPChannelEndpointReservation) throws -> Void)?) async throws
        -> BrowserMCPDevToolsEndpoint
    typealias Revalidate = @Sendable (
        BrowserMCPChannelProcessTarget,
        BrowserMCPDevToolsEndpoint) async throws -> Void

    private let resolveInitial: ResolveInitial
    private let revalidateAuthority: Revalidate

    init(_ resolve: @escaping Resolve, revalidate: @escaping Revalidate) {
        self.resolveInitial = { target, _, _ in try await resolve(target) }
        self.revalidateAuthority = revalidate
    }

    init(
        resolveInitial: @escaping @Sendable (
            BrowserMCPChannelProcessTarget,
            BrowserMCPConnectionAttempt) async throws -> BrowserMCPDevToolsEndpoint,
        revalidate: @escaping Revalidate)
    {
        self.resolveInitial = { target, attempt, _ in try await resolveInitial(target, attempt) }
        self.revalidateAuthority = revalidate
    }

    init(resolveInitialWithReservation: @escaping ResolveInitial, revalidate: @escaping Revalidate) {
        self.resolveInitial = resolveInitialWithReservation
        self.revalidateAuthority = revalidate
    }

    func resolve(
        _ target: BrowserMCPChannelProcessTarget,
        attempt: BrowserMCPConnectionAttempt = .standalone(),
        reserveAuthority: (@MainActor @Sendable (BrowserMCPChannelEndpointReservation) throws -> Void)? = nil)
        async throws -> BrowserMCPDevToolsEndpoint
    {
        try await self.resolveInitial(target, attempt, reserveAuthority)
    }

    func revalidate(
        _ target: BrowserMCPChannelProcessTarget,
        expected: BrowserMCPDevToolsEndpoint) async throws
    {
        try await self.revalidateAuthority(target, expected)
    }

    static let live = BrowserMCPChannelEndpointResolver(
        resolveInitialWithReservation: { target, attempt, reserveAuthority in
            try await Self.resolveEndpoint(
                target: target,
                attempt: attempt,
                activePortURL: Self.activePortURL(
                    channel: target.channel,
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser),
                readActivePort: { url in
                    try StableRegularFileReader.live.read(url, 1024)
                },
                inspectListener: DarwinProcessLoopbackListenerInspector.live.inspect,
                probeWebSocket: BrowserMCPDevToolsWebSocketProber.live.probe,
                reserveAuthority: reserveAuthority)
        },
        revalidate: { target, expected in
            try Self.revalidateEndpoint(
                target: target,
                expected: expected,
                activePortURL: Self.activePortURL(
                    channel: target.channel,
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser),
                readActivePort: { url in
                    try StableRegularFileReader.live.read(url, 1024)
                },
                inspectListener: DarwinProcessLoopbackListenerInspector.live.inspect)
        })

    static func resolveEndpoint(
        target: BrowserMCPChannelProcessTarget,
        attempt: BrowserMCPConnectionAttempt = .standalone(),
        activePortURL: URL,
        readActivePort: @Sendable (URL) throws -> Data,
        inspectListener: DarwinProcessLoopbackListenerInspector.Inspect,
        probeWebSocket: BrowserMCPDevToolsWebSocketProber.Probe,
        reserveAuthority: (@MainActor @Sendable (BrowserMCPChannelEndpointReservation) throws -> Void)? = nil)
        async throws
        -> BrowserMCPDevToolsEndpoint
    {
        let before = try self.resolveAuthority(
            target: target,
            activePortURL: activePortURL,
            readActivePort: readActivePort,
            inspectListener: inspectListener)

        guard let webSocketURL = URL(string: before.webSocketDebuggerURL),
              webSocketURL.absoluteString == before.webSocketDebuggerURL
        else {
            throw BrowserMCPConnectionError.channelEndpointUnavailable(
                target.channel,
                "Chrome's DevToolsActivePort published a malformed WebSocket identity")
        }
        try await reserveAuthority?(BrowserMCPChannelEndpointReservation(
            browserURL: before.browserURL,
            webSocketDebuggerURL: before.webSocketDebuggerURL,
            browserID: before.browserID))
        let version: BrowserMCPDevToolsVersion
        do {
            version = try await probeWebSocket(
                webSocketURL,
                before.browserID,
                attempt.deadline,
                attempt.state.markPermissionDispatchStarted)
        } catch BrowserMCPDevToolsWebSocketProbeFailure.cancelled {
            throw BrowserMCPConnectionError.permissionBearingConnectionCancelled
        } catch let BrowserMCPDevToolsWebSocketProbeFailure.failed(error) {
            throw BrowserMCPConnectionError.permissionBearingConnectionFailed(error.localizedDescription)
        }

        let after: BrowserMCPChannelEndpointAuthority
        do {
            after = try self.resolveAuthority(
                target: target,
                activePortURL: activePortURL,
                readActivePort: readActivePort,
                inspectListener: inspectListener)
        } catch {
            throw BrowserMCPConnectionError.permissionBearingConnectionFailed(
                "Chrome's DevTools authority changed after Browser.getVersion: \(error.localizedDescription)")
        }
        guard after == before else {
            throw BrowserMCPConnectionError.permissionBearingConnectionFailed(
                "Chrome's DevTools authority changed during Browser.getVersion")
        }
        return BrowserMCPDevToolsEndpoint(
            browserURL: before.browserURL,
            webSocketDebuggerURL: before.webSocketDebuggerURL,
            browserID: before.browserID,
            browserVersion: version.browserVersion,
            protocolVersion: version.protocolVersion,
            listenerIdentity: before.listener)
    }

    static func revalidateEndpoint(
        target: BrowserMCPChannelProcessTarget,
        expected: BrowserMCPDevToolsEndpoint,
        activePortURL: URL,
        readActivePort: @Sendable (URL) throws -> Data,
        inspectListener: DarwinProcessLoopbackListenerInspector.Inspect) throws
    {
        let authority = try self.resolveAuthority(
            target: target,
            activePortURL: activePortURL,
            readActivePort: readActivePort,
            inspectListener: inspectListener)
        guard authority.browserURL == expected.browserURL,
              authority.webSocketDebuggerURL == expected.webSocketDebuggerURL,
              authority.browserID == expected.browserID,
              authority.listener == expected.listenerIdentity
        else {
            throw BrowserMCPConnectionError.connectionLost(
                "the process-bound DevTools browser endpoint changed identity")
        }
    }

    private static func resolveAuthority(
        target: BrowserMCPChannelProcessTarget,
        activePortURL: URL,
        readActivePort: @Sendable (URL) throws -> Data,
        inspectListener: DarwinProcessLoopbackListenerInspector.Inspect) throws
        -> BrowserMCPChannelEndpointAuthority
    {
        guard ChromeChannelIdentity(rawValue: target.channel.rawValue)?
            .matches(bundleIdentifier: target.bundleIdentifier) == true
        else {
            throw BrowserMCPConnectionError.channelEndpointUnavailable(
                target.channel,
                "the detected process bundle does not exactly match the requested Chrome channel")
        }
        let activePort: ActivePortRecord
        do {
            activePort = try self.parseActivePort(readActivePort(activePortURL))
        } catch {
            throw BrowserMCPConnectionError.channelEndpointUnavailable(
                target.channel,
                "Chrome's standard-profile DevToolsActivePort could not be read safely: " +
                    error.localizedDescription)
        }
        let listener: DarwinProcessLoopbackListenerIdentity
        do {
            listener = try inspectListener(
                target.processIdentifier,
                target.processStartIdentity,
                activePort.port)
        } catch {
            throw BrowserMCPConnectionError.channelEndpointUnavailable(
                target.channel,
                "Chrome's DevTools listener could not be bound to PID \(target.processIdentifier): " +
                    error.localizedDescription)
        }
        guard listener.processIdentifier == target.processIdentifier,
              listener.processStartIdentity == target.processStartIdentity,
              listener.port == activePort.port
        else {
            throw BrowserMCPConnectionError.channelEndpointUnavailable(
                target.channel,
                "Chrome's DevTools listener inspection returned a different process, generation, or port")
        }
        let browserURL = "http://\(listener.addressFamily.httpHost):\(activePort.port)/"
        let webSocketDebuggerURL =
            "ws://\(listener.addressFamily.httpHost):\(activePort.port)\(activePort.path)"
        return BrowserMCPChannelEndpointAuthority(
            browserURL: browserURL,
            webSocketDebuggerURL: webSocketDebuggerURL,
            browserID: activePort.browserID,
            listener: listener)
    }

    static func activePortURL(channel: BrowserMCPChannel, homeDirectory: URL) -> URL {
        guard let channelIdentity = ChromeChannelIdentity(rawValue: channel.rawValue) else {
            preconditionFailure("Browser channel has no canonical Chrome identity")
        }
        let directoryName = channelIdentity.profileDirectoryName
        return homeDirectory
            .appending(path: "Library/Application Support/Google", directoryHint: .isDirectory)
            .appending(path: directoryName, directoryHint: .isDirectory)
            .appending(path: "DevToolsActivePort", directoryHint: .notDirectory)
    }

    private struct ActivePortRecord {
        let port: UInt16
        let path: String
        let browserID: String
    }

    private static func parseActivePort(_ data: Data) throws -> ActivePortRecord {
        guard !data.isEmpty,
              let value = String(data: data, encoding: .utf8),
              !value.contains("\0")
        else {
            throw BrowserMCPChannelEndpointError.invalidActivePort(
                "Chrome's DevToolsActivePort is not non-empty UTF-8 text")
        }
        var lines = value.split(
            omittingEmptySubsequences: false,
            whereSeparator: \Character.isNewline).map(String.init)
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        guard lines.count == 2,
              !lines[0].isEmpty,
              lines[0].allSatisfy(\.isNumber),
              let parsedPort = UInt16(lines[0]),
              parsedPort > 0
        else {
            throw BrowserMCPChannelEndpointError.invalidActivePort(
                "Chrome's DevToolsActivePort does not contain one valid TCP port and browser path")
        }
        let prefix = "/devtools/browser/"
        guard lines[1].hasPrefix(prefix) else {
            throw BrowserMCPChannelEndpointError.invalidActivePort(
                "Chrome's DevToolsActivePort browser path is malformed")
        }
        let browserID = String(lines[1].dropFirst(prefix.count))
        guard !browserID.isEmpty,
              browserID != ".",
              browserID != "..",
              !browserID.contains("/"),
              !browserID.contains("?"),
              !browserID.contains("#"),
              browserID.utf8.allSatisfy(Self.isUnreservedPathByte)
        else {
            throw BrowserMCPChannelEndpointError.invalidActivePort(
                "Chrome's DevToolsActivePort browser identity is malformed")
        }
        return ActivePortRecord(port: parsedPort, path: lines[1], browserID: browserID)
    }

    private static func isUnreservedPathByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 97...122, 45, 46, 95, 126:
            true
        default:
            false
        }
    }
}

private enum BrowserMCPChannelEndpointError: LocalizedError {
    case invalidActivePort(String)

    var errorDescription: String? {
        switch self {
        case let .invalidActivePort(reason): reason
        }
    }
}
