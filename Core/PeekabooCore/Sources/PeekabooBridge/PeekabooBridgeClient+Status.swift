import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

extension PeekabooBridgeClient {
    public func permissionsStatus() async throws -> PermissionsStatus {
        let response = try await self.send(.permissionsStatus)
        switch response {
        case let .permissionsStatus(status):
            return status
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected permissions response")
        }
    }

    public func requestPostEventPermission() async throws -> Bool {
        let response = try await self.send(.requestPostEventPermission)
        switch response {
        case let .bool(granted):
            return granted
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected permission request response")
        }
    }

    public func daemonStatus() async throws -> PeekabooDaemonStatus {
        let response = try await self.send(.daemonStatus)
        switch response {
        case let .daemonStatus(status):
            return status
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected daemon status response")
        }
    }

    public func daemonStop() async throws -> Bool {
        let response = try await self.send(.daemonStop)
        return try Self.decodeDaemonStopResponse(response)
    }

    public func daemonStop(expectedPID: pid_t) async throws -> Bool {
        let response = try await self.send(.daemonStopIf(.init(expectedPID: expectedPID)))
        return try Self.decodeDaemonStopResponse(response)
    }

    private static func decodeDaemonStopResponse(_ response: PeekabooBridgeResponse) throws -> Bool {
        switch response {
        case let .bool(stopped):
            return stopped
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected daemon stop response")
        }
    }
}
