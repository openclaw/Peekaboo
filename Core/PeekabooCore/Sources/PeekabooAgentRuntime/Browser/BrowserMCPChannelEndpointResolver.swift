import Foundation
import PeekabooAutomationKit

struct BrowserMCPChannelProcessTarget: Sendable, Equatable {
    let channel: BrowserMCPChannel
    let processIdentifier: Int32
    let processStartIdentity: UInt64
    let bundleIdentifier: String
}

struct BrowserMCPChannelEndpointResolver: Sendable {
    typealias Resolve = @Sendable (BrowserMCPChannelProcessTarget) async throws -> BrowserMCPDevToolsEndpoint

    let resolve: Resolve

    static let live = BrowserMCPChannelEndpointResolver { target in
        let activePortURL = Self.activePortURL(
            channel: target.channel,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        return try await Self.resolveEndpoint(
            target: target,
            activePortURL: activePortURL,
            readActivePort: { url in
                try StableRegularFileReader.live.read(url, 1024)
            },
            inspectListener: DarwinProcessLoopbackListenerInspector.live.inspect,
            probeWebSocket: BrowserMCPDevToolsWebSocketProber.live.probe)
    }

    static func resolveEndpoint(
        target: BrowserMCPChannelProcessTarget,
        activePortURL: URL,
        readActivePort: @Sendable (URL) throws -> Data,
        inspectListener: DarwinProcessLoopbackListenerInspector.Inspect,
        probeWebSocket: BrowserMCPDevToolsWebSocketProber.Probe) async throws
        -> BrowserMCPDevToolsEndpoint
    {
        let activePort: ActivePortRecord
        do {
            activePort = try Self.parseActivePort(readActivePort(activePortURL))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BrowserMCPConnectionError.channelEndpointUnavailable(
                target.channel,
                "Chrome's standard-profile DevToolsActivePort could not be read safely: " +
                    error.localizedDescription)
        }

        let before: DarwinProcessLoopbackListenerIdentity
        do {
            before = try inspectListener(
                target.processIdentifier,
                target.processStartIdentity,
                activePort.port)
        } catch {
            throw BrowserMCPConnectionError.channelEndpointUnavailable(
                target.channel,
                "Chrome's DevTools listener could not be bound to PID \(target.processIdentifier): " +
                    error.localizedDescription)
        }
        guard before.processIdentifier == target.processIdentifier,
              before.processStartIdentity == target.processStartIdentity,
              before.port == activePort.port
        else {
            throw BrowserMCPConnectionError.channelEndpointUnavailable(
                target.channel,
                "Chrome's DevTools listener inspection returned a different process, generation, or port")
        }

        let browserURL = "http://\(before.addressFamily.httpHost):\(activePort.port)"
        let webSocketDebuggerURL = "ws://\(before.addressFamily.httpHost):\(activePort.port)\(activePort.path)"
        guard let webSocketURL = URL(string: webSocketDebuggerURL),
              webSocketURL.absoluteString == webSocketDebuggerURL
        else {
            throw BrowserMCPConnectionError.channelEndpointUnavailable(
                target.channel,
                "Chrome's DevToolsActivePort published a malformed WebSocket identity")
        }
        let version: BrowserMCPDevToolsVersion
        do {
            version = try await probeWebSocket(webSocketURL, activePort.browserID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BrowserMCPConnectionError.channelEndpointUnavailable(
                target.channel,
                error.localizedDescription)
        }

        let after: DarwinProcessLoopbackListenerIdentity
        do {
            after = try inspectListener(
                target.processIdentifier,
                target.processStartIdentity,
                activePort.port)
        } catch {
            throw BrowserMCPConnectionError.channelEndpointUnavailable(
                target.channel,
                "Chrome's DevTools listener changed during Browser.getVersion: \(error.localizedDescription)")
        }
        guard after == before else {
            throw BrowserMCPConnectionError.channelEndpointUnavailable(
                target.channel,
                "Chrome's DevTools listener changed during Browser.getVersion")
        }
        return BrowserMCPDevToolsEndpoint(
            browserURL: "\(browserURL)/",
            webSocketDebuggerURL: webSocketDebuggerURL,
            browserID: activePort.browserID,
            browserVersion: version.browserVersion,
            protocolVersion: version.protocolVersion)
    }

    static func activePortURL(channel: BrowserMCPChannel, homeDirectory: URL) -> URL {
        let directoryName = switch channel {
        case .stable: "Chrome"
        case .beta: "Chrome Beta"
        case .dev: "Chrome Dev"
        case .canary: "Chrome Canary"
        }
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
