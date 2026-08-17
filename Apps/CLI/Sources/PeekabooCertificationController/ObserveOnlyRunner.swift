import Darwin
import Foundation

enum CertificationObserveOnlyRunner {
    static func run(planURL: URL) async throws -> URL {
        let planData = try CertificationPrivateArtifacts.readPlan(at: planURL)
        let plan = try CertificationObserveOnlyPlan.decode(planData)
        try CertificationPrivateArtifacts.prepareObserver(for: plan)
        let observer = try LiveForegroundSemanticObserver(plan: plan)
        try await observer.connect()
        let process = await observer.processReceipt()
        let build = await observer.buildReceipt()

        let baselineValue = try await observer.readSemanticValue()
        let baselineSHA256 = CertificationPrivateArtifacts.sha256(Data(baselineValue.utf8))
        guard baselineSHA256 == plan.baselineValueSHA256 else {
            throw CertificationControllerError.runtimeRefusal(
                "Foreground semantic baseline value does not match the owner plan."
            )
        }
        let focusedElement = try await observer.focusedElementReceipt()
        try self.writeJSON(
            CertificationObserverReadyReceipt(
                version: 1,
                mode: .observeOnly,
                executionNonce: plan.executionNonce,
                observerID: plan.observerID,
                observer: process,
                observerBuild: build,
                target: plan.target,
                focusedElement: focusedElement,
                requestMarker: plan.requestMarker,
                baselineValueSHA256: baselineSHA256,
                expectedValueSHA256: plan.expectedValueSHA256,
                observationPath: plan.observationPath,
                restorationPath: plan.restorationPath,
                readyAtMilliseconds: self.nowMilliseconds()
            ),
            to: plan.readyURL
        )

        try await self.waitForMarker(.observe, at: plan.observationRequestURL, plan: plan)
        let observationStarted = self.nowMilliseconds()
        let observedValue = try await observer.readSemanticValue()
        let observationCompleted = self.nowMilliseconds()
        let observedSHA256 = CertificationPrivateArtifacts.sha256(Data(observedValue.utf8))
        guard observedValue == plan.requestMarker,
              observedSHA256 == plan.expectedValueSHA256
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Foreground semantic readback does not contain the exact expected postcondition token."
            )
        }
        try self.writeJSON(
            CertificationForegroundReadbackDocument(
                version: 1,
                executionNonce: plan.executionNonce,
                requestMarker: plan.requestMarker,
                target: plan.target,
                observer: process,
                observedValueSHA256: observedSHA256,
                observedAtMilliseconds: observationCompleted
            ),
            to: plan.observationURL
        )
        let observationFileSHA256 = try CertificationPrivateArtifacts.sha256(file: plan.observationURL)

        try await self.waitForMarker(.restore, at: plan.restorationRequestURL, plan: plan)
        let restoredValue = try await observer.readSemanticValue()
        let restoredAt = self.nowMilliseconds()
        let restoredSHA256 = CertificationPrivateArtifacts.sha256(Data(restoredValue.utf8))
        guard restoredSHA256 == baselineSHA256 else {
            throw CertificationControllerError.runtimeRefusal(
                "Foreground semantic value was not restored to its authenticated baseline."
            )
        }
        try self.writeJSON(
            CertificationForegroundReadbackDocument(
                version: 1,
                executionNonce: plan.executionNonce,
                requestMarker: plan.requestMarker,
                target: plan.target,
                observer: process,
                observedValueSHA256: restoredSHA256,
                observedAtMilliseconds: restoredAt
            ),
            to: plan.restorationURL
        )
        let restorationFileSHA256 = try CertificationPrivateArtifacts.sha256(file: plan.restorationURL)
        try self.writeJSON(
            CertificationForegroundPostconditionWitness(
                version: 1,
                executionNonce: plan.executionNonce,
                target: plan.target,
                observer: process,
                focusedElement: focusedElement,
                interval: CertificationIntervalReceipt(
                    startedAtMilliseconds: observationStarted,
                    completedAtMilliseconds: observationCompleted
                ),
                requestMarker: plan.requestMarker,
                beforeValueSHA256: baselineSHA256,
                expectedValueSHA256: plan.expectedValueSHA256,
                observedValueSHA256: observedSHA256,
                restoredValueSHA256: restoredSHA256,
                observationPath: plan.observationPath,
                observationFileSHA256: observationFileSHA256,
                restorationPath: plan.restorationPath,
                restorationFileSHA256: restorationFileSHA256,
                passed: true,
                restored: true
            ),
            to: plan.witnessURL
        )
        let witnessSHA256 = try CertificationPrivateArtifacts.sha256(file: plan.witnessURL)
        let attestationServer = try CertificationObserverAttestationServer(
            socketPath: plan.attestationSocketPath,
            executionNonce: plan.executionNonce,
            monitorInstanceID: plan.monitorInstanceID,
            observer: process,
            witnessSHA256: witnessSHA256,
            observationFileSHA256: observationFileSHA256,
            restorationFileSHA256: restorationFileSHA256,
            beforeValueSHA256: baselineSHA256,
            expectedValueSHA256: plan.expectedValueSHA256,
            observedValueSHA256: observedSHA256,
            restoredValueSHA256: restoredSHA256
        )
        let serverTask = Task.detached { await attestationServer.serve() }
        do {
            try await self.waitForMarker(.release, at: plan.releaseURL, plan: plan)
        } catch {
            attestationServer.stop()
            serverTask.cancel()
            await serverTask.value
            throw error
        }
        attestationServer.stop()
        serverTask.cancel()
        await serverTask.value
        return plan.witnessURL
    }

    static func waitForMarker(
        _ phase: CertificationObserverRequestMarker.Phase,
        at url: URL,
        plan: CertificationObserveOnlyPlan
    ) async throws {
        try await self.waitForMarker(
            phase,
            at: url,
            plan: plan,
            timeout: .seconds(plan.waitTimeoutSeconds),
            pollInterval: .milliseconds(plan.pollIntervalMilliseconds)
        )
    }

    static func waitForMarker(
        _ phase: CertificationObserverRequestMarker.Phase,
        at url: URL,
        plan: CertificationObserveOnlyPlan,
        timeout: Duration,
        pollInterval: Duration
    ) async throws {
        let deadline = CertificationContinuousDeadline(timeout: timeout)
        while deadline.hasTimeRemaining {
            var info = stat()
            if lstat(url.path, &info) == 0 {
                let data = try CertificationPrivateArtifacts.readPlan(at: url)
                let object = try JSONSerialization.jsonObject(with: data)
                guard let dictionary = object as? [String: Any],
                      Set(dictionary.keys) == ["version", "execution_nonce", "request_marker", "phase"]
                else {
                    throw CertificationControllerError.runtimeRefusal(
                        "Observe-only owner request marker keys are not closed."
                    )
                }
                let marker = try JSONDecoder().decode(CertificationObserverRequestMarker.self, from: data)
                guard marker.version == 1,
                      marker.executionNonce == plan.executionNonce,
                      marker.requestMarker == plan.requestMarker,
                      marker.phase == phase
                else {
                    throw CertificationControllerError.runtimeRefusal(
                        "Observe-only owner request marker is not bound to the exact run and phase."
                    )
                }
                return
            }
            guard errno == ENOENT else {
                throw CertificationControllerError.unsafePrivatePath(
                    "Cannot inspect observe-only owner request marker."
                )
            }
            try await deadline.sleep(upTo: pollInterval)
        }
        throw CertificationControllerError.runtimeRefusal(
            "Timed out waiting for observe-only owner request marker \(phase.rawValue)."
        )
    }

    private static func writeJSON(_ value: some Encodable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        try CertificationPrivateArtifacts.writeReceipt(data, to: url)
    }

    private static func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
    }
}
