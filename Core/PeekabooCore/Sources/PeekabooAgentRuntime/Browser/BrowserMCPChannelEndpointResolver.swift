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
            resolveDevToolsEndpoint: BrowserMCPDevToolsEndpointResolver.live.resolve)
    }

    static func resolveEndpoint(
        target: BrowserMCPChannelProcessTarget,
        activePortURL: URL,
        readActivePort: @Sendable (URL) throws -> Data,
        inspectListener: DarwinProcessLoopbackListenerInspector.Inspect,
        resolveDevToolsEndpoint: BrowserMCPDevToolsEndpointResolver.Resolve) async throws
        -> BrowserMCPDevToolsEndpoint
    {
        let activePort: ActivePortRecord
        do {
            activePort = try Self.parseActivePort(readActivePort(activePortURL))
        } catch let error as BrowserMCPConnectionError {
            throw error
        } catch {
            throw BrowserMCPConnectionError.invalidEndpoint(
                "Chrome's DevToolsActivePort could not be read safely: \(error.localizedDescription)")
        }

        let before: DarwinProcessLoopbackListenerIdentity
        do {
            before = try inspectListener(
                target.processIdentifier,
                target.processStartIdentity,
                activePort.port)
        } catch {
            throw BrowserMCPConnectionError.invalidEndpoint(
                "Chrome's DevTools listener could not be bound to PID \(target.processIdentifier): " +
                    error.localizedDescription)
        }

        let browserURL = "http://\(before.addressFamily.httpHost):\(activePort.port)"
        let endpoint = try await resolveDevToolsEndpoint(browserURL)
        guard endpoint.browserID == activePort.browserID else {
            throw BrowserMCPConnectionError.invalidEndpoint(
                "DevToolsActivePort and /json/version reported different browser identities")
        }

        let after: DarwinProcessLoopbackListenerIdentity
        do {
            after = try inspectListener(
                target.processIdentifier,
                target.processStartIdentity,
                activePort.port)
        } catch {
            throw BrowserMCPConnectionError.invalidEndpoint(
                "Chrome's DevTools listener changed during /json/version: \(error.localizedDescription)")
        }
        guard after == before else {
            throw BrowserMCPConnectionError.invalidEndpoint(
                "Chrome's DevTools listener changed during /json/version")
        }
        return endpoint
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
        let browserID: String
    }

    private static func parseActivePort(_ data: Data) throws -> ActivePortRecord {
        guard !data.isEmpty,
              let value = String(data: data, encoding: .utf8),
              !value.contains("\0")
        else {
            throw BrowserMCPConnectionError.invalidEndpoint(
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
            throw BrowserMCPConnectionError.invalidEndpoint(
                "Chrome's DevToolsActivePort does not contain one valid TCP port and browser path")
        }
        let prefix = "/devtools/browser/"
        guard lines[1].hasPrefix(prefix) else {
            throw BrowserMCPConnectionError.invalidEndpoint(
                "Chrome's DevToolsActivePort browser path is malformed")
        }
        let browserID = String(lines[1].dropFirst(prefix.count))
        guard !browserID.isEmpty,
              !browserID.contains("/"),
              !browserID.contains("?"),
              !browserID.contains("#"),
              browserID.allSatisfy({ $0.isASCII && !$0.isWhitespace })
        else {
            throw BrowserMCPConnectionError.invalidEndpoint(
                "Chrome's DevToolsActivePort browser identity is malformed")
        }
        return ActivePortRecord(port: parsedPort, browserID: browserID)
    }
}
