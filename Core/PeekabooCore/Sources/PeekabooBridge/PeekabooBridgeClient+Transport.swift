import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

extension PeekabooBridgeClient {
    func send(
        _ request: PeekabooBridgeRequest,
        timeoutSec: TimeInterval? = nil) async throws -> PeekabooBridgeResponse
    {
        try await self.sendCarryingActionOutcome(request, timeoutSec: timeoutSec).response
    }

    func sendCarryingActionOutcome(
        _ request: PeekabooBridgeRequest,
        timeoutSec: TimeInterval? = nil) async throws -> PeekabooBridgeTransportReply
    {
        if case .handshake = request {
            // Handshake resets are owned by `handshake(client:)`.
        } else {
            self.latestVerifiedOperationReceipt = nil
            self.latestVerifiedOperationReceiptBundle = nil
        }
        let explicitlyProjected = if case .projectedAction = request {
            true
        } else {
            false
        }
        let expectsProjectedResponse = explicitlyProjected ||
            (self.actionProjectionEnabled && request.mayMutateDesktop)
        let projectedRequest = expectsProjectedResponse && !explicitlyProjected
            ? PeekabooBridgeRequest.projectedAction(.init(request: request))
            : request
        let preparedRequest = try self.prepareWireRequest(projectedRequest)
        let attestedContext = preparedRequest.context
        let wireRequest = preparedRequest.request
        let payload = try self.encoder.encode(wireRequest)
        let op = request.operation
        let start = Date()
        self.logger.debug("Sending bridge request \(op.rawValue, privacy: .public)")

        let effectiveTimeoutSec = timeoutSec ?? self.requestTimeoutSec
        let (socketPath, maxResponseBytes, requestTimeoutSec) =
            (self.socketPath, self.maxResponseBytes, effectiveTimeoutSec)
        let cancellation = PeekabooBridgeClientConnectionCancellation()
        let responseData: Data
        do {
            responseData = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try Self.sendBlocking(
                        .init(
                            socketPath: socketPath,
                            requestData: payload,
                            maxResponseBytes: maxResponseBytes,
                            timeoutSec: requestTimeoutSec,
                            expectedListener: attestedContext?.attestation),
                        cancellation: cancellation)
                }.value
            } onCancel: {
                cancellation.cancel()
            }
        } catch let failure as PeekabooBridgeResponseReadFailure {
            guard request.mayMutateDesktop else {
                throw failure.underlying
            }
            throw Self.responseLostFailure(
                operation: op,
                causeDescription: "\(failure.underlying)",
                requestID: attestedContext?.requestID)
        }
        guard !responseData.isEmpty else {
            let details = """
            EOF while reading response for \(op.rawValue).

            This usually means the host closed the socket before replying \
            (often due to an authorization/TeamID check). \
            Update Peekaboo.app / ClawdBot.app to a host build that returns a structured \
            `unauthorizedClient` response, or launch the host with \
            PEEKABOO_ALLOW_UNSIGNED_SOCKET_CLIENTS=1 for local development.
            """

            guard request.mayMutateDesktop else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .internalError,
                    message: "Bridge host returned no response",
                    details: details)
            }
            throw Self.responseLostFailure(
                operation: op,
                causeDescription: details,
                requestID: attestedContext?.requestID)
        }

        let wireResponse: PeekabooBridgeResponse
        do {
            wireResponse = try self.decoder.decode(PeekabooBridgeResponse.self, from: responseData)
        } catch {
            guard request.mayMutateDesktop else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .decodingFailed,
                    message: "Bridge host returned an invalid response",
                    details: "\(error)")
            }
            throw Self.responseLostFailure(
                operation: op,
                causeDescription: "Bridge response decoding failed: \(error)",
                requestID: attestedContext?.requestID)
        }
        let verifiedWireResponse: PeekabooBridgeResponse
        var verifiedTargetIdentity: DesktopTargetIdentity?
        do {
            let verified = try Self.verifyAttestedResponse(
                wireResponse,
                context: attestedContext)
            verifiedWireResponse = verified.response
            if let bundle = verified.bundle {
                verifiedTargetIdentity = try bundle.receipt.payload.resolvedTargetIdentity()
                self.latestVerifiedOperationReceipt = bundle.receipt
                self.latestVerifiedOperationReceiptBundle = bundle
                try Self.exportOperationReceiptIfRequested(
                    bundle,
                    directory: self.operationReceiptExportDirectory)
            }
        } catch {
            guard request.mayMutateDesktop else { throw error }
            throw Self.responseLostFailure(
                operation: op,
                causeDescription: "Bridge operation receipt validation failed: \(error.localizedDescription)",
                requestID: attestedContext?.requestID)
        }
        let unwrappedReply = try Self.unwrapResponse(
            verifiedWireResponse,
            expectsProjectedResponse: expectsProjectedResponse,
            request: request)
        let reply = PeekabooBridgeTransportReply(
            response: unwrappedReply.response,
            outcome: unwrappedReply.outcome,
            targetIdentity: verifiedTargetIdentity)
        let response = reply.response
        if case let .error(envelope) = response,
           request.mayMutateDesktop
        {
            if let failure = envelope.desktopActionFailure {
                throw failure
            }
            if envelope.operationMayHaveCompleted {
                throw Self.legacyCompletionUnknownFailure(envelope: envelope)
            }
        }
        let duration = Date().timeIntervalSince(start)
        self.logger.debug(
            "bridge \(op.rawValue, privacy: .public) completed in \(duration, format: .fixed(precision: 3))s")
        return reply
    }

    private func prepareWireRequest(
        _ request: PeekabooBridgeRequest) throws -> PeekabooBridgePreparedRequest
    {
        guard let attestation = self.operationAttestation else {
            return .init(request: request, context: nil)
        }
        if case .handshake = request {
            return .init(request: request, context: nil)
        }

        let processIdentifier = getpid()
        guard let processStartIdentity = SystemIdentityResolver.processStartIdentity(processIdentifier) else {
            throw PeekabooBridgeErrorEnvelope(
                code: .internalError,
                message: "Could not establish the Bridge client's process-generation receipt")
        }
        guard let codeSignatureHash = PeekabooBridgeCodeSignatureIdentity.codeSignatureHash(
            processIdentifier: processIdentifier)
        else {
            throw PeekabooBridgeErrorEnvelope(
                code: .internalError,
                message: "Could not establish the Bridge client's code-signature receipt")
        }
        let requestID = UUID()
        let clientIdentity = PeekabooBridgeOperationProcessIdentity(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity,
            codeSignatureHash: codeSignatureHash)
        let context = PeekabooBridgeAttestedRequestContext(
            requestID: requestID,
            attestation: attestation,
            clientIdentity: clientIdentity,
            request: request)
        return .init(
            request: .attestedOperation(.init(
                requestID: requestID,
                expectedListenerInstanceID: attestation.listenerInstanceID,
                client: clientIdentity,
                request: request)),
            context: context)
    }

    private nonisolated static func unwrapResponse(
        _ response: PeekabooBridgeResponse,
        expectsProjectedResponse: Bool,
        request: PeekabooBridgeRequest) throws -> PeekabooBridgeTransportReply
    {
        if expectsProjectedResponse {
            guard case let .projectedAction(payload) = response else {
                throw self.responseLostFailure(
                    operation: request.operation,
                    causeDescription: "A projection-capable Bridge host returned an unwrapped action response")
            }
            if case .projectedAction = payload.response {
                throw Self.responseLostFailure(
                    operation: request.operation,
                    causeDescription: "A projection-capable Bridge host returned nested action carriage")
            }
            if case let .error(envelope) = payload.response,
               payload.outcome != envelope.actionOutcome
            {
                throw Self.responseLostFailure(
                    operation: request.operation,
                    causeDescription: "Bridge action response and error envelope carried contradictory outcomes")
            }
            return PeekabooBridgeTransportReply(
                response: payload.response,
                outcome: payload.outcome)
        }

        guard case .projectedAction = response else {
            return PeekabooBridgeTransportReply(response: response, outcome: nil)
        }
        if request.mayMutateDesktop {
            throw self.responseLostFailure(
                operation: request.operation,
                causeDescription: "Bridge host returned unrequested action projection carriage")
        }
        throw PeekabooBridgeErrorEnvelope(
            code: .decodingFailed,
            message: "Bridge host returned an unexpected projected response")
    }

    func sendExpectOK(
        _ request: PeekabooBridgeRequest,
        timeoutSec: TimeInterval? = nil) async throws
    {
        let response = try await self.send(request, timeoutSec: timeoutSec)
        switch response {
        case .ok:
            return
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected response for void request")
        }
    }

    func sendExpectOKCarryingActionOutcome(
        _ request: PeekabooBridgeRequest,
        timeoutSec: TimeInterval? = nil) async throws -> DesktopActionOutcome?
    {
        let reply = try await self.sendCarryingActionOutcome(request, timeoutSec: timeoutSec)
        switch reply.response {
        case .ok:
            return reply.outcome?.outcome
        case let .error(envelope):
            try Self.throwActionFailureOrEnvelope(envelope)
        default:
            throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected response for void request")
        }
    }

    nonisolated static func throwActionFailureOrEnvelope(
        _ envelope: PeekabooBridgeErrorEnvelope) throws -> Never
    {
        if let failure = envelope.desktopActionFailure {
            throw failure
        }
        throw envelope
    }

    private nonisolated static func disableSigPipe(fd: Int32) {
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
    }

    private nonisolated static func sendBlocking(
        _ request: PeekabooBridgeBlockingRequest,
        cancellation: PeekabooBridgeClientConnectionCancellation) throws -> Data
    {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try cancellation.install(fd: fd)
        defer {
            cancellation.clear(fd: fd)
            close(fd)
        }

        do {
            Self.disableSigPipe(fd: fd)
            try PeekabooBridgeSocketIO.configureConnectedSocket(fd)
            let deadline = Date().addingTimeInterval(request.timeoutSec)

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: addr.sun_path)
            let copied = request.socketPath.withCString { cstr -> Int in
                strlcpy(&addr.sun_path.0, cstr, capacity)
            }
            guard copied < capacity else { throw POSIXError(.ENAMETOOLONG) }
            addr.sun_len = UInt8(MemoryLayout.size(ofValue: addr))

            let len = socklen_t(MemoryLayout.size(ofValue: addr))
            let connectResult = withUnsafePointer(to: &addr) { ptr in
                connect(fd, UnsafePointer<sockaddr>(OpaquePointer(ptr)), len)
            }
            if connectResult != 0 {
                guard errno == EINPROGRESS || errno == EAGAIN || errno == EALREADY else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
                }
                try PeekabooBridgeSocketIO.finishConnect(fd: fd, deadline: deadline)
            }

            if let expectedListener = request.expectedListener {
                try expectedListener.validateSignature()
                let auditIdentity = try PeekabooBridgeSocketIO.peerAuditIdentity(fd: fd)
                guard auditIdentity.processIdentifier == expectedListener.host.processIdentifier,
                      SystemIdentityResolver.processStartIdentity(auditIdentity.processIdentifier) ==
                      expectedListener.host.processStartIdentity,
                      PeekabooBridgeCodeSignatureIdentity.codeSignatureHash(
                          auditIdentity: auditIdentity) == expectedListener.host.codeSignatureHash
                else {
                    throw PeekabooBridgeOperationReceiptError.peerIdentityMismatch
                }
            }

            try cancellation.check()
            try PeekabooBridgeSocketIO.writeAll(fd: fd, data: request.requestData, deadline: deadline)
            do {
                guard shutdown(fd, SHUT_WR) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                let response = try PeekabooBridgeSocketIO.readAll(
                    fd: fd,
                    maxBytes: request.maxResponseBytes,
                    deadline: deadline)
                try cancellation.check()
                return response
            } catch {
                let responseFailure: any Error
                do {
                    try cancellation.check()
                    responseFailure = error
                } catch let cancellationError {
                    responseFailure = cancellationError
                }
                throw PeekabooBridgeResponseReadFailure(underlying: responseFailure)
            }
        } catch let responseFailure as PeekabooBridgeResponseReadFailure {
            throw responseFailure
        } catch {
            try cancellation.check()
            throw error
        }
    }

    private nonisolated static func responseLostFailure(
        operation: PeekabooBridgeOperation,
        causeDescription: String,
        requestID: UUID? = nil) -> DesktopActionFailure
    {
        let requestSuffix = requestID.map { "; request_id=\($0.uuidString.lowercased())" } ?? ""
        let message = "Bridge response was lost after \(operation.rawValue) was dispatched; " +
            "outcome is indeterminate; do not retry\(requestSuffix)"
        return DesktopActionFailure.indeterminate(
            route: .bridge,
            evidence: .responseLost,
            message: message,
            hint: "Observe the target before retrying this operation.",
            causeDescription: causeDescription)
    }

    private nonisolated static func verifyAttestedResponse(
        _ response: PeekabooBridgeResponse,
        context: PeekabooBridgeAttestedRequestContext?) throws
        -> (response: PeekabooBridgeResponse, bundle: PeekabooBridgeOperationReceiptBundle?)
    {
        guard let context else {
            guard case .attestedOperation = response else { return (response, nil) }
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("an unrequested receipt envelope")
        }
        guard case let .attestedOperation(envelope) = response else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("the required receipt envelope")
        }
        guard case .attestedOperation = envelope.response else {
            let receipt = envelope.receipt
            try receipt.validateSignature(publicKey: context.attestation.publicKey)
            let payload = receipt.payload
            guard payload.schemaVersion == 1 else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("schema_version")
            }
            guard payload.requestID == context.requestID else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("request_id")
            }
            guard payload.listenerInstanceID == context.attestation.listenerInstanceID,
                  payload.listenerPublicKeySHA256 == PeekabooBridgeOperationReceiptCoding.sha256(
                      context.attestation.publicKey),
                  payload.host == context.attestation.host
            else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("listener identity")
            }
            guard payload.client == context.clientIdentity else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("client identity")
            }
            guard payload.operation == context.request.operation,
                  try payload.requestSHA256 == (PeekabooBridgeOperationReceiptCoding.sha256(context.request)),
                  try payload.responseSHA256 == (PeekabooBridgeOperationReceiptCoding.sha256(envelope.response)),
                  payload.outcome == PeekabooBridgeOperationReceiptSemantics.outcome(in: envelope.response),
                  payload.completedAtUnixMilliseconds >= payload.startedAtUnixMilliseconds
            else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("operation facts")
            }
            try PeekabooBridgeOperationReceiptSemantics.validateTargetAttribution(
                payload,
                request: context.request,
                response: envelope.response)
            let bundle = try PeekabooBridgeOperationReceiptBundle(
                operationAttestation: context.attestation,
                receipt: receipt,
                canonicalListenerAttestationPayload: PeekabooBridgeOperationReceiptCoding.canonicalData(
                    context.attestation.unsignedPayload),
                canonicalReceiptPayload: PeekabooBridgeOperationReceiptCoding.canonicalData(receipt.payload),
                canonicalRequest: PeekabooBridgeOperationReceiptCoding.canonicalData(context.request),
                canonicalResponse: PeekabooBridgeOperationReceiptCoding.canonicalData(envelope.response))
            try bundle.validate()
            return (envelope.response, bundle)
        }
        throw PeekabooBridgeOperationReceiptError.receiptMismatch("a nested receipt envelope")
    }

    private nonisolated static func exportOperationReceiptIfRequested(
        _ bundle: PeekabooBridgeOperationReceiptBundle,
        directory: URL?) throws
    {
        guard let directory else { return }
        let directoryURL = directory.standardizedFileURL
        let destination = directoryURL.appendingPathComponent(
            bundle.receipt.payload.requestID.uuidString.lowercased() + ".json",
            isDirectory: false)
        try PeekabooBridgePrivateReceiptArchive.writeAtomically(
            PeekabooBridgeOperationReceiptCoding.canonicalData(bundle),
            to: destination)
    }

    private nonisolated static func legacyCompletionUnknownFailure(
        envelope: PeekabooBridgeErrorEnvelope) -> DesktopActionFailure
    {
        DesktopActionFailure.indeterminate(
            route: .bridge,
            evidence: .completionUnknown,
            message: envelope.message,
            hint: "Observe the target before retrying this operation.",
            causeDescription: envelope.details)
    }
}

struct PeekabooBridgeTransportReply: Sendable {
    let response: PeekabooBridgeResponse
    let outcome: DesktopActionOutcome.Projection?
    let targetIdentity: DesktopTargetIdentity?

    init(
        response: PeekabooBridgeResponse,
        outcome: DesktopActionOutcome.Projection?,
        targetIdentity: DesktopTargetIdentity? = nil)
    {
        self.response = response
        self.outcome = outcome
        self.targetIdentity = targetIdentity
    }
}

private struct PeekabooBridgeAttestedRequestContext: Sendable {
    let requestID: UUID
    let attestation: PeekabooBridgeListenerAttestation
    let clientIdentity: PeekabooBridgeOperationProcessIdentity
    let request: PeekabooBridgeRequest
}

private struct PeekabooBridgePreparedRequest: Sendable {
    let request: PeekabooBridgeRequest
    let context: PeekabooBridgeAttestedRequestContext?
}

private struct PeekabooBridgeBlockingRequest: Sendable {
    let socketPath: String
    let requestData: Data
    let maxResponseBytes: Int
    let timeoutSec: TimeInterval
    let expectedListener: PeekabooBridgeListenerAttestation?
}

private struct PeekabooBridgeResponseReadFailure: Error {
    let underlying: any Error
}

/// Wakes blocking socket I/O when the Swift caller is cancelled. The blocking worker remains the sole owner of
/// `close(2)` so cancellation cannot close a descriptor that the kernel has already recycled for another request.
final class PeekabooBridgeClientConnectionCancellation: @unchecked Sendable {
    typealias ShutdownHandler = @Sendable (Int32) -> Void

    private let lock = NSLock()
    private let shutdownHandler: ShutdownHandler
    private var fileDescriptor: Int32?
    private var isCancelled = false

    init(shutdownHandler: @escaping ShutdownHandler = { fd in
        _ = shutdown(fd, SHUT_RDWR)
    }) {
        self.shutdownHandler = shutdownHandler
    }

    func install(fd: Int32) throws {
        self.lock.lock()
        if self.isCancelled {
            self.lock.unlock()
            close(fd)
            throw CancellationError()
        }
        self.fileDescriptor = fd
        self.lock.unlock()
    }

    func cancel() {
        self.lock.lock()
        self.isCancelled = true
        if let fd = self.fileDescriptor {
            // `clear(fd:)` cannot release this descriptor for close/reuse until shutdown completes.
            self.shutdownHandler(fd)
        }
        self.lock.unlock()
    }

    func clear(fd: Int32) {
        self.lock.lock()
        if self.fileDescriptor == fd {
            self.fileDescriptor = nil
        }
        self.lock.unlock()
    }

    func check() throws {
        self.lock.lock()
        let isCancelled = self.isCancelled
        self.lock.unlock()
        if isCancelled {
            throw CancellationError()
        }
    }
}
