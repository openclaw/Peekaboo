import Foundation
import os.log
import PeekabooFoundation

@MainActor
extension PeekabooBridgeServer {
    func route(
        _ request: PeekabooBridgeRequest,
        peer: PeekabooBridgePeer?) async throws -> PeekabooBridgeHandledResponse
    {
        let plan = PeekabooBridgeOperationResultSemantics.requestPlan(
            for: request,
            vocabulary: .init(usesCurrentResultSemantics:
                PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics))
        return try await self.route(plan, peer: peer)
    }

    func route(
        _ plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan,
        peer: PeekabooBridgePeer?) async throws -> PeekabooBridgeHandledResponse
    {
        let request = plan.request
        do {
            try self.validatePeerAuthorization(peer)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            throw PeekabooBridgeOperationResultSemantics.canonicalFailure(
                envelope,
                plan: plan,
                stage: .preDispatch(.transportSessionUnavailable))
        }
        do {
            try PeekabooBridgeRequestContext.checkRequestIsActive()
        } catch {
            throw PeekabooBridgeOperationResultSemantics.canonicalFailure(
                .init(code: .timeout, message: "Bridge request was cancelled before dispatch"),
                plan: plan,
                stage: .preDispatch(.requestCancelled))
        }

        let start = Date()
        let pid = peer?.processIdentifier ?? 0
        var failed = false
        defer {
            if !failed {
                let duration = Date().timeIntervalSince(start)
                let durationString = String(format: "%.3f", duration)
                self.logger.debug(
                    """
                    bridge op=\(request.operation.rawValue, privacy: .public) \
                    pid=\(pid, privacy: .public) ok in \(durationString, privacy: .public)s
                    """)
            }
        }

        let op = request.operation
        let permissions = self.currentPermissions()
        let effectiveOps = self.effectiveAllowedOperations(for: request, permissions: permissions)

        do {
            try request.validatePlatformIdentifierBounds()
            try self.validateOperationAccess(
                for: plan,
                peer: peer,
                permissions: permissions,
                effectiveOps: effectiveOps)
        } catch let diagnostic as ScreenCaptureKitOwnershipDiagnostic {
            failed = true
            throw PeekabooBridgeOperationResultSemantics.canonicalFailure(
                Self.bridgeErrorEnvelope(for: diagnostic, operation: op),
                plan: plan,
                stage: .preDispatch(.runtimeIncompatible))
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            failed = true
            let duration = Date().timeIntervalSince(start)
            let durationString = String(format: "%.3f", duration)
            self.logger.error(
                """
                bridge op=\(op.rawValue, privacy: .public) pid=\(pid, privacy: .public) \
                code=\(envelope.code.rawValue, privacy: .public) failed in \(durationString, privacy: .public)s
                """)
            throw PeekabooBridgeOperationResultSemantics.canonicalFailure(
                envelope,
                plan: plan,
                stage: .preDispatch(PeekabooBridgeOperationResultSemantics.preDispatchReason(for: envelope)))
        }

        do {
            return try await self.withDaemonActivity(for: plan) {
                let response = try await self.handleAuthorizedWithDesktopMutationBarrier(
                    plan,
                    peer: peer,
                    permissions: permissions)
                return try PeekabooBridgeOperationResultSemantics.finalizeSuccessful(
                    plan: plan,
                    handled: response)
            }
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            failed = true
            let duration = Date().timeIntervalSince(start)
            let durationString = String(format: "%.3f", duration)
            self.logger.error(
                """
                bridge op=\(op.rawValue, privacy: .public) pid=\(pid, privacy: .public) \
                code=\(envelope.code.rawValue, privacy: .public) failed in \(durationString, privacy: .public)s
                """)
            throw PeekabooBridgeOperationResultSemantics.canonicalFailure(
                envelope,
                plan: plan,
                stage: .executionMayHaveStarted)
        } catch {
            failed = true
            let duration = Date().timeIntervalSince(start)
            let durationString = String(format: "%.3f", duration)
            self.logger.error(
                """
                bridge op=\(op.rawValue, privacy: .public) pid=\(pid, privacy: .public) \
                code=internal_error failed in \(durationString, privacy: .public)s
                """)

            throw PeekabooBridgeOperationResultSemantics.canonicalFailure(
                Self.bridgeErrorEnvelope(for: error, operation: op),
                plan: plan,
                stage: .executionMayHaveStarted)
        }
    }

    private func withDaemonActivity<Value>(
        for plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan,
        operation: () async throws -> Value) async throws -> Value
    {
        let request = plan.request
        let op = request.operation
        guard let daemonControl = self.daemonControl,
              op != .daemonStatus,
              op != .daemonStop
        else {
            return try await operation()
        }

        if let conditionalControl = daemonControl as? any PeekabooConditionalDaemonControlProviding {
            guard await conditionalControl.admitActivity(operation: op) else {
                throw PeekabooBridgeOperationResultSemantics.canonicalFailure(
                    .init(code: .serverBusy, message: "Daemon is shutting down"),
                    plan: plan,
                    stage: .preDispatch(.transportSessionUnavailable))
            }
        } else {
            await daemonControl.recordActivityStart(operation: op)
        }

        let result: Result<Value, any Error>
        do {
            let value = try await operation()
            result = .success(value)
        } catch {
            result = .failure(error)
        }
        await daemonControl.recordActivityEnd(operation: op)
        return try result.get()
    }
}
