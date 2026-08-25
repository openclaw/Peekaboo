import Foundation
import PeekabooFoundation

struct BrowserMCPDevToolsVersion: Sendable, Equatable {
    let browserVersion: String
    let protocolVersion: String
}

enum BrowserMCPDevToolsWebSocketProbeError: LocalizedError, Equatable {
    case connectionRefused(String)
    case timedOut
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case let .connectionRefused(reason):
            "the exact DevTools WebSocket refused Browser.getVersion: \(reason)"
        case .timedOut:
            "the exact DevTools WebSocket did not complete Browser.getVersion before the approval timeout"
        case let .malformedResponse(reason):
            "the exact DevTools WebSocket returned an invalid Browser.getVersion response: \(reason)"
        }
    }
}

enum BrowserMCPDevToolsWebSocketProbeFailure: LocalizedError, Equatable {
    case cancelled
    case failed(BrowserMCPDevToolsWebSocketProbeError)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "the permission-bearing DevTools WebSocket exchange was cancelled after it started"
        case let .failed(error):
            error.localizedDescription
        }
    }
}

struct BrowserMCPDevToolsWebSocketProber: Sendable {
    typealias Exchange = @Sendable (
        URLRequest,
        String,
        Int,
        @escaping @Sendable () -> Void) async throws -> Data
    typealias Probe = @Sendable (
        URL,
        String,
        ContinuousClock.Instant,
        @escaping @Sendable () -> Void) async throws -> BrowserMCPDevToolsVersion

    let probe: Probe

    static let live = BrowserMCPDevToolsWebSocketProber { url, browserID, deadline, onDispatch in
        try await Self.probeVersion(
            url,
            expectedBrowserID: browserID,
            deadline: deadline,
            onDispatch: onDispatch,
            exchange: Self.liveExchange)
    }

    static func probeVersion(
        _ webSocketURL: URL,
        expectedBrowserID: String,
        deadline: ContinuousClock.Instant,
        onDispatch: @escaping @Sendable () -> Void = {},
        exchange: @escaping Exchange) async throws -> BrowserMCPDevToolsVersion
    {
        try self.validate(webSocketURL, expectedBrowserID: expectedBrowserID)
        let clock = ContinuousClock()
        let approvalDeadline = min(
            deadline,
            clock.now.advanced(by: .seconds(BrowserConnectionTiming.approvalTimeoutSeconds)))
        let remaining = clock.now.duration(to: approvalDeadline)
        guard remaining > .zero else {
            throw BrowserMCPDevToolsWebSocketProbeError.timedOut
        }

        let requestID = 1
        var mutableRequest = URLRequest(url: webSocketURL)
        mutableRequest.cachePolicy = .reloadIgnoringLocalCacheData
        mutableRequest.timeoutInterval = self.timeInterval(remaining)
        let request = mutableRequest
        let command = #"{"id":1,"method":"Browser.getVersion"}"#
        let dispatchMarker = BrowserMCPWebSocketDispatchMarker(onDispatch: onDispatch)

        do {
            let data = try await Self.withTimeout(remaining) {
                try await exchange(request, command, requestID, dispatchMarker.markDispatched)
            }
            return try self.parseVersion(data, requestID: requestID)
        } catch is CancellationError {
            if dispatchMarker.didDispatch {
                throw BrowserMCPDevToolsWebSocketProbeFailure.cancelled
            }
            throw CancellationError()
        } catch let failure as BrowserMCPDevToolsWebSocketProbeFailure {
            throw failure
        } catch let error as BrowserMCPDevToolsWebSocketProbeError {
            if dispatchMarker.didDispatch {
                throw BrowserMCPDevToolsWebSocketProbeFailure.failed(error)
            }
            throw error
        } catch {
            let error = BrowserMCPDevToolsWebSocketProbeError.connectionRefused(error.localizedDescription)
            if dispatchMarker.didDispatch {
                throw BrowserMCPDevToolsWebSocketProbeFailure.failed(error)
            }
            throw error
        }
    }

    private static func parseVersion(_ data: Data, requestID: Int) throws -> BrowserMCPDevToolsVersion {
        guard data.count <= 64 * 1024 else {
            throw BrowserMCPDevToolsWebSocketProbeError.malformedResponse("the response exceeded 64 KiB")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseID = object["id"] as? Int,
              responseID == requestID
        else {
            throw BrowserMCPDevToolsWebSocketProbeError.malformedResponse("the response ID was missing or wrong")
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Chrome returned a CDP error"
            throw BrowserMCPDevToolsWebSocketProbeError.connectionRefused(message)
        }
        guard let result = object["result"] as? [String: Any],
              let product = result["product"] as? String,
              product.hasPrefix("Chrome/"),
              product.count > "Chrome/".count,
              let protocolVersion = result["protocolVersion"] as? String,
              !protocolVersion.isEmpty
        else {
            throw BrowserMCPDevToolsWebSocketProbeError.malformedResponse(
                "Chrome product and protocolVersion were not both present")
        }
        return BrowserMCPDevToolsVersion(browserVersion: product, protocolVersion: protocolVersion)
    }

    private static func timeInterval(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }

    private static func validate(_ url: URL, expectedBrowserID: String) throws {
        guard url.scheme == "ws",
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              let host = url.host,
              ["127.0.0.1", "::1"].contains(host),
              url.port != nil,
              url.path == "/devtools/browser/\(expectedBrowserID)"
        else {
            throw BrowserMCPDevToolsWebSocketProbeError.malformedResponse(
                "the requested WebSocket was not the exact published loopback browser identity")
        }
    }

    private static func liveExchange(
        _ request: URLRequest,
        _ command: String,
        _ requestID: Int,
        _ onDispatch: @escaping @Sendable () -> Void) async throws -> Data
    {
        let task = BrowserMCPNoRedirectURLSession.shared.webSocketTask(with: request)
        return try await withTaskCancellationHandler {
            defer { task.cancel(with: .normalClosure, reason: nil) }
            try Task.checkCancellation()
            onDispatch()
            task.resume()
            try await task.send(.string(command))
            while true {
                let message = try await task.receive()
                let data = switch message {
                case let .data(data): data
                case let .string(string): Data(string.utf8)
                @unknown default:
                    throw BrowserMCPDevToolsWebSocketProbeError.malformedResponse(
                        "Chrome returned an unsupported WebSocket message")
                }
                guard data.count <= 64 * 1024 else {
                    throw BrowserMCPDevToolsWebSocketProbeError.malformedResponse(
                        "the response exceeded 64 KiB")
                }
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return data
                }
                if let responseID = object["id"] as? Int {
                    guard responseID == requestID else {
                        throw BrowserMCPDevToolsWebSocketProbeError.malformedResponse(
                            "Chrome returned a response for an unexpected CDP request")
                    }
                    return data
                }
                guard object["method"] is String else {
                    return data
                }
            }
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    private static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T) async throws -> T
    {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw BrowserMCPDevToolsWebSocketProbeError.timedOut
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }
}

private final class BrowserMCPWebSocketDispatchMarker: @unchecked Sendable {
    private let lock = NSLock()
    private let onDispatch: @Sendable () -> Void
    private var dispatched = false

    init(onDispatch: @escaping @Sendable () -> Void) {
        self.onDispatch = onDispatch
    }

    var didDispatch: Bool {
        self.lock.withLock { self.dispatched }
    }

    func markDispatched() {
        let shouldNotify = self.lock.withLock {
            guard !self.dispatched else { return false }
            self.dispatched = true
            return true
        }
        if shouldNotify {
            self.onDispatch()
        }
    }
}
