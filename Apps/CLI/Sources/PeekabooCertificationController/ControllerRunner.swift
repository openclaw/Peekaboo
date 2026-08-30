import Darwin
import Foundation

struct CertificationContinuousDeadline {
    private let clock: ContinuousClock
    private let instant: ContinuousClock.Instant

    init(timeout: Duration) {
        let clock = ContinuousClock()
        self.clock = clock
        self.instant = clock.now.advanced(by: timeout)
    }

    var hasTimeRemaining: Bool {
        self.clock.now < self.instant
    }

    func sleep(upTo pollInterval: Duration) async throws {
        let now = self.clock.now
        guard now < self.instant else { return }
        try await self.clock.sleep(for: min(pollInterval, now.duration(to: self.instant)))
    }
}

enum CertificationControllerRunner {
    static func run(planURL: URL) async throws -> URL {
        let planData = try CertificationPrivateArtifacts.readPlan(at: planURL)
        let plan = try CertificationControllerPlan.decode(planData)
        try CertificationPrivateArtifacts.prepare(for: plan)
        let startedAt = Self.nowMilliseconds()
        let bridge = try LiveCertificationBridge(plan: plan)
        let handshake = try await bridge.connect()
        try await bridge.preflightReady()
        let controllerProcess = await bridge.controllerProcessReceipt()
        let controllerBuild = await bridge.controllerBuildReceipt()
        try self.writeJSON(
            CertificationControllerReadyReceipt(
                version: 1,
                executionNonce: plan.executionNonce,
                controllerID: plan.controllerID,
                targetID: plan.targetID,
                controller: controllerProcess,
                build: controllerBuild,
                readyAtMilliseconds: Self.nowMilliseconds()
            ),
            to: plan.readyURL
        )
        try await CertificationControllerLifecycleGate.waitForStart(
            at: plan.startURL,
            executionNonce: plan.executionNonce,
            controllerID: plan.controllerID
        )
        guard let sessionID = UUID(uuidString: handshake.session.id),
              let listenerInstanceID = UUID(uuidString: handshake.listenerInstanceID)
        else {
            throw CertificationControllerError.runtimeRefusal("Authenticated session identifiers are malformed.")
        }
        var ledger = CertificationRunLedger(
            plan: plan,
            sessionID: sessionID,
            listenerInstanceID: listenerInstanceID
        )
        for slot in plan.slots.dropLast() {
            try await ledger.append(bridge.execute(slot))
        }
        let completedSlotIDs = try ledger.finalBoundsReadySlotIDs()
        try self.writeJSON(
            CertificationFinalBoundsReadyReceipt(
                version: 1,
                executionNonce: plan.executionNonce,
                monitorInstanceID: plan.monitorInstanceID,
                controllerID: plan.controllerID,
                targetID: plan.targetID,
                controller: controllerProcess,
                completedSlotIDs: completedSlotIDs,
                readyAtMilliseconds: Self.nowMilliseconds()
            ),
            to: plan.finalBoundsReadyURL
        )
        try await CertificationControllerLifecycleGate.waitForFinalBoundsStart(
            at: plan.finalBoundsStartURL,
            executionNonce: plan.executionNonce,
            monitorInstanceID: plan.monitorInstanceID,
            controllerID: plan.controllerID
        )
        guard let finalBoundsSlot = plan.slots.last,
              finalBoundsSlot.checkpoint == "final-bounds"
        else {
            throw CertificationControllerError.runtimeRefusal("Controller final-bounds slot is missing.")
        }
        try await ledger.append(bridge.execute(finalBoundsSlot))
        let exportedIDs = await bridge.exportedIDs()
        guard exportedIDs.count == plan.slots.count else {
            throw CertificationControllerError.runtimeRefusal("Controller did not export exactly four bundles.")
        }
        try CertificationPrivateArtifacts.requireExactBundleInventory(
            plan.bundleDirectoryURL,
            requestIDs: exportedIDs
        )
        let receipt = try CertificationControllerReceipt(
            version: 1,
            result: "passed",
            executionNonce: plan.executionNonce,
            monitorInstanceID: plan.monitorInstanceID,
            controllerID: plan.controllerID,
            targetID: plan.targetID,
            controller: controllerProcess,
            build: controllerBuild,
            handshake: handshake,
            target: CertificationWindowReceipt(target: plan.target),
            interval: CertificationIntervalReceipt(
                startedAtMilliseconds: startedAt,
                completedAtMilliseconds: Self.nowMilliseconds()
            ),
            slots: ledger.validatedReceipts()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var receiptData = try encoder.encode(receipt)
        receiptData.append(0x0A)
        try CertificationPrivateArtifacts.writeReceipt(receiptData, to: plan.receiptURL)
        try await CertificationControllerLifecycleGate.waitForRelease(
            at: plan.releaseURL,
            executionNonce: plan.executionNonce
        )
        return plan.receiptURL
    }

    private static func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
    }

    private static func writeJSON(_ value: some Encodable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        try CertificationPrivateArtifacts.writeReceipt(data, to: url)
    }
}

enum CertificationControllerLifecycleGate {
    static func waitForStart(
        at url: URL,
        executionNonce: String,
        controllerID: String,
        timeout: Duration = .seconds(3600),
        pollInterval: Duration = .milliseconds(50)
    ) async throws {
        try await self.wait(
            at: url,
            marker: MarkerExpectation(name: "start", keys: ["version", "execution_nonce", "controller_id", "phase"]),
            timeout: timeout,
            pollInterval: pollInterval
        ) { data in
            let marker = try JSONDecoder().decode(CertificationControllerStartMarker.self, from: data)
            try marker.validate(executionNonce: executionNonce, controllerID: controllerID)
        }
    }

    static func waitForRelease(
        at url: URL,
        executionNonce: String,
        timeout: Duration = .seconds(3600),
        pollInterval: Duration = .milliseconds(50)
    ) async throws {
        try await self.wait(
            at: url,
            marker: MarkerExpectation(name: "release", keys: ["version", "execution_nonce", "phase"]),
            timeout: timeout,
            pollInterval: pollInterval
        ) { data in
            let marker = try JSONDecoder().decode(CertificationControllerReleaseMarker.self, from: data)
            try marker.validate(executionNonce: executionNonce)
        }
    }

    static func waitForFinalBoundsStart(
        at url: URL,
        executionNonce: String,
        monitorInstanceID: String,
        controllerID: String,
        timeout: Duration = .seconds(3600),
        pollInterval: Duration = .milliseconds(50)
    ) async throws {
        try await self.wait(
            at: url,
            marker: MarkerExpectation(
                name: "final-bounds start",
                keys: ["version", "execution_nonce", "monitor_instance_id", "controller_id", "phase"]
            ),
            timeout: timeout,
            pollInterval: pollInterval
        ) { data in
            let marker = try JSONDecoder().decode(CertificationFinalBoundsStartMarker.self, from: data)
            try marker.validate(
                executionNonce: executionNonce,
                monitorInstanceID: monitorInstanceID,
                controllerID: controllerID
            )
        }
    }

    private struct MarkerExpectation {
        let name: String
        let keys: Set<String>
    }

    private static func wait(
        at url: URL,
        marker: MarkerExpectation,
        timeout: Duration,
        pollInterval: Duration,
        validate: (Data) throws -> Void
    ) async throws {
        let deadline = CertificationContinuousDeadline(timeout: timeout)
        while deadline.hasTimeRemaining {
            var info = stat()
            if lstat(url.path, &info) == 0 {
                let data = try CertificationPrivateArtifacts.readPlan(at: url)
                let object = try JSONSerialization.jsonObject(with: data)
                guard let dictionary = object as? [String: Any],
                      Set(dictionary.keys) == marker.keys
                else {
                    throw CertificationControllerError.runtimeRefusal(
                        "Controller lifecycle marker keys are not closed."
                    )
                }
                try validate(data)
                return
            }
            guard errno == ENOENT else {
                throw CertificationControllerError.unsafePrivatePath(
                    "Cannot inspect controller \(marker.name) marker at \(url.path)."
                )
            }
            try await deadline.sleep(upTo: pollInterval)
        }
        throw CertificationControllerError.runtimeRefusal(
            "Timed out waiting for the owner-private controller \(marker.name) marker at \(url.path)."
        )
    }
}
