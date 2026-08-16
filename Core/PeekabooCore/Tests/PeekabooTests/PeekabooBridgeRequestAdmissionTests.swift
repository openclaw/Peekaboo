import CoreGraphics
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

@Suite(.serialized)
struct PeekabooBridgeRequestAdmissionTests {
    @Test
    func `nonpositive request capacity clamps to one`() throws {
        let tracker = PeekabooBridgeRequestTracker(maximumActiveRequestCount: 0)
        let first = try #require(tracker.begin())
        #expect(tracker.begin() == nil)
        tracker.finish(first)
        let replacement = try #require(tracker.begin())
        tracker.finish(replacement)
    }

    @Test
    func `slow partial readers use bounded body capacity without consuming request admission`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbra-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let decodes = RequestDecodeProbe()
        let server = await MainActor.run {
            let server = PeekabooBridgeServer(
                services: StubServices(),
                allowlistedTeams: [],
                allowlistedBundles: [],
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
                })
            server.setRequestDecodeObserverForTesting { decodes.record() }
            return server
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2,
            maximumConcurrentRequests: 1)
        try await host.startChecked()

        do {
            var partialReaders: [Int32] = []
            defer { partialReaders.forEach { close($0) } }
            for _ in 0..<4 {
                try partialReaders.append(Self.connect(socketPath))
            }
            #expect(try await Self.waitUntil { await host.activeBodyReadCountForTesting() == 4 })
            #expect(await host.activeRequestCountForTesting() == 0)
            #expect(decodes.isEmpty)

            let waitingFD = try Self.connect(socketPath)
            defer { close(waitingFD) }
            let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(
                PeekabooBridgeRequest.permissionsStatus)
            try PeekabooBridgeSocketIO.writeAll(
                fd: waitingFD,
                data: requestData,
                deadline: Date().addingTimeInterval(1))
            #expect(shutdown(waitingFD, SHUT_WR) == 0)
            try await Task.sleep(for: .milliseconds(50))
            #expect(decodes.isEmpty)
            #expect(await host.activeRequestCountForTesting() == 0)
            #expect(await host.activeBodyReadCountForTesting() == 4)

            close(partialReaders.removeFirst())
            let responseData = try PeekabooBridgeSocketIO.readAll(
                fd: waitingFD,
                maxBytes: 1024 * 1024,
                deadline: Date().addingTimeInterval(1))
            guard case .permissionsStatus = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeResponse.self,
                from: responseData)
            else {
                Issue.record("Expected the admitted request to complete")
                await host.stop()
                return
            }
            #expect(decodes.count == 2)
            #expect(try await Self.waitUntil { await host.activeRequestCountForTesting() == 0 })
            partialReaders.forEach { close($0) }
            partialReaders.removeAll()
            #expect(try await Self.waitUntil { await host.activeBodyReadCountForTesting() == 0 })
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }

    @Test
    func `accepted connection flood stays below liveness and task capacity`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbrc-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
                allowlistedTeams: [],
                allowlistedBundles: [])
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2,
            maximumConcurrentRequests: 1)
        try await host.startChecked()

        var clients: [Int32] = []
        defer { clients.forEach { close($0) } }
        for _ in 0..<24 {
            try clients.append(Self.connect(socketPath))
        }
        #expect(try await Self.waitUntil { await host.activeConnectionCountForTesting() == 8 })
        let capacity = await host.acceptedConnectionCapacityForTesting()
        #expect(capacity.active == 8)
        #expect(capacity.peak == 8)
        #expect(capacity.maximum == 8)
        #expect(try await Self.waitUntil { await host.activeBodyReadCountForTesting() == 4 })
        let activeRequestCount = await host.activeRequestCountForTesting()
        #expect(activeRequestCount == 0)
        #expect(try await Self.waitUntil {
            clients.filter { !PeekabooBridgeSocketIO.peerCanReceiveResponse(fd: $0) }.count >= 16
        })

        clients.forEach { close($0) }
        clients.removeAll()
        #expect(try await Self.waitUntil { await host.activeConnectionCountForTesting() == 0 })
        #expect(try await Self.waitUntil { await host.activeBodyReadCountForTesting() == 0 })
        let releasedCapacity = await host.acceptedConnectionCapacityForTesting()
        #expect(releasedCapacity.active == 0)
        await host.stop()
    }

    @Test
    @MainActor
    func `saturated decoded mutation receives signed retry safe refusal without dispatch`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbrs-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let observations = BlockingAdmissionObservationService()
        let server = PeekabooBridgeServer(
            services: StubServices(desktopObservation: observations),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation])
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2,
            maximumConcurrentRequests: 1)
        try await host.startChecked()

        let blocker = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
        let attested = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let legacy = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
        let clientIdentity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peekaboo.request-admission-tests",
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: nil)
        _ = try await blocker.handshake(client: clientIdentity, protocolVersion: .init(major: 1, minor: 28))
        _ = try await attested.handshake(client: clientIdentity)
        _ = try await legacy.handshake(client: clientIdentity, protocolVersion: .init(major: 1, minor: 28))

        let blockingTask = Task {
            try await blocker.send(.desktopObservation(Self.mutatingObservationRequest(snapshotID: "blocking")))
        }
        await observations.waitUntilFirstObservationStarted()
        #expect(await host.activeRequestCountForTesting() == 1)
        defer { observations.releaseFirstObservation() }

        do {
            _ = try await attested.send(.desktopObservation(Self.mutatingObservationRequest(snapshotID: "signed")))
            Issue.record("Expected signed capacity refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(!failure.outcome.dispatchState.mutationDispatched)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.outcome.refusalReason == .transportSessionUnavailable)
            #expect(failure.outcome.escalation == .reconnectSession)
        } catch {
            Issue.record("Expected canonical signed refusal, got \(error)")
        }
        let bundle = try #require(await attested.lastOperationReceiptBundle())
        let signedResponse = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: bundle.canonicalResponse)
        guard case let .projectedAction(projected) = signedResponse,
              case let .error(signedEnvelope) = projected.response
        else {
            Issue.record("Expected signed projected server-busy response")
            observations.releaseFirstObservation()
            _ = try await blockingTask.value
            await host.stop()
            return
        }
        #expect(signedEnvelope.code == .serverBusy)
        #expect(signedEnvelope.actionOutcome?.retrySafe == true)
        #expect(signedEnvelope.actionOutcome?.mutationDispatched == false)

        do {
            _ = try await legacy.send(.desktopObservation(Self.mutatingObservationRequest(snapshotID: "legacy")))
            Issue.record("Expected receiptless projected capacity refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(!failure.outcome.dispatchState.mutationDispatched)
            #expect(failure.outcome.retrySafety == .safe)
        } catch {
            Issue.record("Expected projected legacy refusal, got \(error)")
        }
        #expect(observations.observationCount == 1)

        observations.releaseFirstObservation()
        guard case .desktopObservation = try await blockingTask.value else {
            Issue.record("Expected blocking observation response")
            await host.stop()
            return
        }
        await host.stop()
    }

    @Test
    @MainActor
    func `target dependent read only admission refusals are signed targetless and keep session valid`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbrt-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let observations = BlockingAdmissionObservationService()
        let server = PeekabooBridgeServer(
            services: StubServices(desktopObservation: observations),
            allowlistedTeams: [],
            allowlistedBundles: [])
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2,
            maximumConcurrentRequests: 1)
        try await host.startChecked()

        let blocker = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
        let attested = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let clientIdentity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peekaboo.read-only-admission-tests",
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: nil)
        _ = try await blocker.handshake(client: clientIdentity, protocolVersion: .init(major: 1, minor: 28))
        _ = try await attested.handshake(client: clientIdentity)

        let blockingTask = Task {
            try await blocker.send(.desktopObservation(Self.mutatingObservationRequest(snapshotID: "blocking")))
        }
        await observations.waitUntilFirstObservationStarted()
        defer { observations.releaseFirstObservation() }

        let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)
        let windowIdentity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 9001,
            capturedBounds: bounds)
        let windowContext = WindowContext(
            applicationName: "Fixture",
            applicationBundleId: "dev.peekaboo.fixture",
            applicationProcessId: windowIdentity.ownerProcessIdentifier,
            windowTitle: "Fixture",
            windowID: windowIdentity.windowID,
            windowBounds: bounds,
            windowMutationIdentity: windowIdentity,
            shouldFocusWebContent: false)
        let requests: [(String, PeekabooBridgeRequest)] = [
            (
                "capture window",
                .captureWindow(.init(
                    appIdentifier: "",
                    windowIndex: nil,
                    windowId: windowIdentity.windowID,
                    visualizerMode: .none,
                    scale: .logical1x))),
            (
                "capture frontmost",
                .captureFrontmost(.init(visualizerMode: .none, scale: .logical1x))),
            (
                "observe exact window",
                .desktopObservation(Self.passiveObservationRequest(
                    target: .windowID(CGWindowID(windowIdentity.windowID)),
                    snapshotID: "passive-window"))),
            (
                "observe frontmost",
                .desktopObservation(Self.passiveObservationRequest(
                    target: .frontmost,
                    snapshotID: "passive-frontmost"))),
            (
                "inspect exact window",
                .inspectAccessibilityTree(.init(windowContext: windowContext))),
        ]
        var previousReceipt: PeekabooBridgeOperationReceipt?
        for (label, request) in requests {
            #expect(!request.mayMutateDesktop, "\(label) must remain read-only")
            let response = try await attested.send(request)
            let bundle = try #require(await attested.lastOperationReceiptBundle())
            try bundle.validate()
            Self.expectTargetlessAdmissionRefusal(response, bundle: bundle, label: label)
            if label == "capture window" {
                Self.expectTargetlessAdmissionForgeryRejections(
                    request: request,
                    response: response,
                    bundle: bundle)
            }
            if let previousReceipt {
                #expect(bundle.receipt.payload.sessionID == previousReceipt.payload.sessionID)
                #expect(bundle.receipt.payload.sessionSequence.value ==
                    previousReceipt.payload.sessionSequence.value + 1)
            }
            previousReceipt = bundle.receipt
        }
        #expect(observations.observationCount == 1)

        observations.releaseFirstObservation()
        guard case .desktopObservation = try await blockingTask.value else {
            Issue.record("Expected blocking observation response")
            await host.stop()
            return
        }
        guard case .permissionsStatus = try await attested.send(.permissionsStatus) else {
            Issue.record("Expected the same signed session to remain usable after admission refusals")
            await host.stop()
            return
        }
        await host.stop()
    }

    @Test
    @MainActor
    func `refusal signing lane bounds flooded decoded mutations`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbrf-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let observations = BlockingAdmissionObservationService()
        let refusalGate = AdmissionRefusalGate()
        let server = PeekabooBridgeServer(
            services: StubServices(desktopObservation: observations),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.desktopObservation])
        server.setAdmissionRefusalObserverForTesting {
            await refusalGate.enter()
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2,
            maximumConcurrentRequests: 1)
        try await host.startChecked()

        let blocker = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
        let attested = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let clientIdentity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peekaboo.request-admission-flood-tests",
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: nil)
        _ = try await blocker.handshake(client: clientIdentity, protocolVersion: .init(major: 1, minor: 28))
        _ = try await attested.handshake(client: clientIdentity)

        let blockingTask = Task {
            try await blocker.send(.desktopObservation(Self.mutatingObservationRequest(snapshotID: "blocking")))
        }
        await observations.waitUntilFirstObservationStarted()
        defer { observations.releaseFirstObservation() }

        let floodTasks = (0..<6).map { index in
            Task {
                do {
                    _ = try await attested.send(.desktopObservation(
                        Self.mutatingObservationRequest(snapshotID: "refusal-\(index)")))
                    return false
                } catch let failure as DesktopActionFailure {
                    return failure.outcome.state == .refused &&
                        !failure.outcome.dispatchState.mutationDispatched &&
                        failure.outcome.retrySafety == .safe
                } catch {
                    return false
                }
            }
        }
        await refusalGate.waitUntilEntered()
        let refusalCapacity = await host.admissionRefusalCapacityForTesting()
        #expect(refusalCapacity.active == 1)
        #expect(refusalCapacity.peak == 1)
        #expect(refusalCapacity.maximum == 1)
        #expect(observations.observationCount == 1)

        await refusalGate.release()
        var safeRefusalCount = 0
        for task in floodTasks {
            safeRefusalCount += await task.value ? 1 : 0
        }
        #expect(safeRefusalCount == floodTasks.count)
        #expect(observations.observationCount == 1)
        let completedRefusalCapacity = await host.admissionRefusalCapacityForTesting()
        #expect(completedRefusalCapacity.peak == 1)
        #expect(await attested.lastOperationReceiptBundle() != nil)

        observations.releaseFirstObservation()
        _ = try await blockingTask.value
        server.setAdmissionRefusalObserverForTesting(nil)
        await host.stop()
    }

    @Test
    func `draining host decodes once and returns structured no dispatch refusal`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbrd-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let decodes = RequestDecodeProbe()
        let server = await MainActor.run {
            let server = PeekabooBridgeServer(
                services: StubServices(),
                allowlistedTeams: [],
                allowlistedBundles: [])
            server.setRequestDecodeObserverForTesting { decodes.record() }
            return server
        }
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        await host.stopAcceptingRequestsForTesting()

        let fd = try Self.connect(socketPath)
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(
            PeekabooBridgeRequest.permissionsStatus)
        _ = requestData.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        _ = shutdown(fd, SHUT_WR)
        let responseData = try PeekabooBridgeSocketIO.readAll(
            fd: fd,
            maxBytes: 1024 * 1024,
            deadline: Date().addingTimeInterval(1))
        close(fd)

        guard case let .error(envelope) = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: responseData)
        else {
            Issue.record("Expected structured draining refusal")
            await host.stop()
            return
        }
        #expect(envelope.code == .serverBusy)
        #expect(!envelope.operationMayHaveCompleted)
        #expect(decodes.count == 1)
        #expect(await host.activeRequestCountForTesting() == 0)
        await host.stop()
    }

    private static func mutatingObservationRequest(snapshotID: String) -> DesktopObservationRequest {
        DesktopObservationRequest(
            target: .screen(index: 0),
            capture: DesktopCaptureOptions(focus: .background),
            detection: DesktopDetectionOptions(mode: .accessibility, allowWebFocusFallback: true),
            output: DesktopObservationOutputOptions(snapshotID: snapshotID))
    }

    private static func passiveObservationRequest(
        target: DesktopObservationTargetRequest,
        snapshotID: String) -> DesktopObservationRequest
    {
        DesktopObservationRequest(
            target: target,
            capture: DesktopCaptureOptions(focus: .background),
            detection: DesktopDetectionOptions(mode: .accessibility, allowWebFocusFallback: false),
            output: DesktopObservationOutputOptions(snapshotID: snapshotID))
    }

    private static func expectTargetlessAdmissionRefusal(
        _ response: PeekabooBridgeResponse,
        bundle: PeekabooBridgeOperationReceiptBundle,
        label: String)
    {
        guard case let .error(envelope) = response else {
            Issue.record("Expected signed server-busy refusal for \(label)")
            return
        }
        #expect(envelope.code == .serverBusy)
        #expect(envelope.actionOutcome?.outcome.state == .refused)
        #expect(envelope.actionOutcome?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(envelope.actionOutcome?.retrySafe == true)
        #expect(envelope.actionOutcome?.outcome.refusalReason == .transportSessionUnavailable)
        #expect(bundle.receipt.payload.target == nil)
        #expect(bundle.receipt.payload.focusedElement == nil)
        #expect(bundle.receipt.payload.targetAttributionFailure == nil)
        #expect(bundle.receipt.payload.targetAttributionEvidence == nil)
        #expect(bundle.receipt.payload.outcome == envelope.actionOutcome)
    }

    private static func expectTargetlessAdmissionForgeryRejections(
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse,
        bundle: PeekabooBridgeOperationReceiptBundle)
    {
        let original = bundle.receipt.payload
        let forgedGlobal = PeekabooBridgeOperationReceiptPayload(
            requestID: original.requestID,
            sessionID: original.sessionID,
            sessionSequence: original.sessionSequence,
            sessionAttestationSHA256: original.sessionAttestationSHA256,
            listenerInstanceID: original.listenerInstanceID,
            listenerPublicKeySHA256: original.listenerPublicKeySHA256,
            host: original.host,
            clientInstanceID: original.clientInstanceID,
            client: original.client,
            operation: original.operation,
            requestSHA256: original.requestSHA256,
            responseSHA256: original.responseSHA256,
            target: .global,
            outcome: original.outcome,
            remainingClaimCount: original.remainingClaimCount,
            startedAtUnixMilliseconds: original.startedAtUnixMilliseconds,
            completedAtUnixMilliseconds: original.completedAtUnixMilliseconds)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try PeekabooBridgeOperationReceiptSemantics.validateTargetAttribution(
                forgedGlobal,
                request: request,
                response: response)
        }

        let missingOutcome = PeekabooBridgeResponse.error(.init(
            code: .serverBusy,
            message: "Bridge request capacity is temporarily saturated",
            details: "The decoded request was refused before desktop dispatch."))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try PeekabooBridgeOperationReceiptSemantics.validateTargetAttribution(
                original,
                request: request,
                response: missingOutcome)
        }
    }

    private static func connect(_ socketPath: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try PeekabooBridgeSocketIO.configureConnectedSocket(fd)
            var noSigPipe: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe)))
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout.size(ofValue: address))
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            let copied = socketPath.withCString { strlcpy(&address.sun_path.0, $0, capacity) }
            guard copied < capacity else { throw POSIXError(.ENAMETOOLONG) }
            let addressLength = socklen_t(MemoryLayout.size(ofValue: address))
            let result = withUnsafePointer(to: &address) {
                Darwin.connect(
                    fd,
                    UnsafePointer<sockaddr>(OpaquePointer($0)),
                    addressLength)
            }
            if result != 0 {
                guard errno == EINPROGRESS || errno == EAGAIN || errno == EALREADY else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
                }
                try PeekabooBridgeSocketIO.finishConnect(fd: fd, deadline: Date().addingTimeInterval(1))
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping () async -> Bool) async throws -> Bool
    {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() {
                return true
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

@MainActor
private final class BlockingAdmissionObservationService: DesktopObservationServiceProtocol {
    private(set) var observationCount = 0
    private var firstObservationStarted = false
    private var firstObservationStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstObservationContinuation: CheckedContinuation<Void, Never>?

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        self.observationCount += 1
        if self.observationCount == 1 {
            self.firstObservationStarted = true
            self.firstObservationStartWaiters.forEach { $0.resume() }
            self.firstObservationStartWaiters.removeAll()
            await withCheckedContinuation { continuation in
                self.firstObservationContinuation = continuation
            }
        }
        return DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .screen(index: 0)),
            capture: CaptureResult(
                imageData: StubScreenCaptureService.sampleData,
                savedPath: "/tmp/\(request.output.snapshotID ?? "stub").png",
                metadata: CaptureMetadata(
                    size: .init(width: 1, height: 1),
                    mode: .screen,
                    timestamp: Date())),
            elements: nil,
            files: DesktopObservationFiles())
    }

    func waitUntilFirstObservationStarted() async {
        guard !self.firstObservationStarted else { return }
        await withCheckedContinuation { continuation in
            self.firstObservationStartWaiters.append(continuation)
        }
    }

    func releaseFirstObservation() {
        self.firstObservationContinuation?.resume()
        self.firstObservationContinuation = nil
    }
}

private actor AdmissionRefusalGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        self.entered = true
        self.entryWaiters.forEach { $0.resume() }
        self.entryWaiters.removeAll()
        guard !self.released else { return }
        await withCheckedContinuation { continuation in
            self.releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !self.entered else { return }
        await withCheckedContinuation { continuation in
            self.entryWaiters.append(continuation)
        }
    }

    func release() {
        self.released = true
        self.releaseWaiters.forEach { $0.resume() }
        self.releaseWaiters.removeAll()
    }
}

private final class RequestDecodeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var invocationCount = 0

    var count: Int {
        self.lock.withLock { self.invocationCount }
    }

    var isEmpty: Bool {
        self.lock.withLock { self.invocationCount == 0 }
    }

    func record() {
        self.lock.withLock { self.invocationCount += 1 }
    }
}
