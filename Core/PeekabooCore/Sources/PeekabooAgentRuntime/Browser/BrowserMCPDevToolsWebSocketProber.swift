import Foundation

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

struct BrowserMCPDevToolsWebSocketProber: Sendable {
    typealias Exchange = @Sendable (URLRequest, String, Int) async throws -> Data
    typealias Probe = @Sendable (URL, String) async throws -> BrowserMCPDevToolsVersion

    let probe: Probe

    static let live = BrowserMCPDevToolsWebSocketProber { url, browserID in
        try await Self.probeVersion(
            url,
            expectedBrowserID: browserID,
            timeout: .seconds(60),
            exchange: Self.liveExchange)
    }

    static func probeVersion(
        _ webSocketURL: URL,
        expectedBrowserID: String,
        timeout: Duration,
        exchange: @escaping Exchange) async throws -> BrowserMCPDevToolsVersion
    {
        try self.validate(webSocketURL, expectedBrowserID: expectedBrowserID)
        guard timeout > .zero else {
            throw BrowserMCPDevToolsWebSocketProbeError.timedOut
        }

        let requestID = 1
        var mutableRequest = URLRequest(url: webSocketURL)
        mutableRequest.cachePolicy = .reloadIgnoringLocalCacheData
        mutableRequest.timeoutInterval = 60
        let request = mutableRequest
        let command = #"{"id":1,"method":"Browser.getVersion"}"#

        let data: Data
        do {
            data = try await Self.withTimeout(timeout) {
                try await exchange(request, command, requestID)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BrowserMCPDevToolsWebSocketProbeError {
            throw error
        } catch {
            throw BrowserMCPDevToolsWebSocketProbeError.connectionRefused(error.localizedDescription)
        }

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
        return BrowserMCPDevToolsVersion(
            browserVersion: product,
            protocolVersion: protocolVersion)
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
        _ requestID: Int) async throws -> Data
    {
        let task = BrowserMCPNoRedirectURLSession.shared.webSocketTask(with: request)
        return try await withTaskCancellationHandler {
            defer { task.cancel(with: .normalClosure, reason: nil) }
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
