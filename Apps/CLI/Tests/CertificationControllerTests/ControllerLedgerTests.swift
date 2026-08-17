import Foundation
import Testing
@testable import PeekabooCertificationController

@Suite("Certification controller stable session ledger")
struct ControllerLedgerTests {
    @Test
    func `ledger accepts exactly four marker-bound ordered sequences`() throws {
        let plan = try CertificationControllerPlan.decode(ControllerPlanTests.validPlanData)
        let sessionID = try #require(UUID(uuidString: "019c0000-0000-4000-8000-000000000010"))
        let listenerID = try #require(UUID(uuidString: "019c0000-0000-4000-8000-000000000011"))
        var ledger = CertificationRunLedger(
            plan: plan,
            sessionID: sessionID,
            listenerInstanceID: listenerID
        )

        for (ordinal, slot) in plan.slots.enumerated() {
            try ledger.append(Self.evidence(
                plan: plan,
                slot: slot,
                ordinal: ordinal,
                sessionID: sessionID,
                listenerID: listenerID
            ))
        }

        let receipts = try ledger.validatedReceipts()
        #expect(receipts.map(\.sessionSequence) == ["0", "1", "2", "3"])
        #expect(Set(receipts.map(\.requestID)).count == 4)
    }

    @Test
    func `ledger refuses a replacement session before recording evidence`() throws {
        let plan = try CertificationControllerPlan.decode(ControllerPlanTests.validPlanData)
        let sessionID = try #require(UUID(uuidString: "019c0000-0000-4000-8000-000000000010"))
        let replacement = try #require(UUID(uuidString: "019c0000-0000-4000-8000-000000000012"))
        let listenerID = try #require(UUID(uuidString: "019c0000-0000-4000-8000-000000000011"))
        var ledger = CertificationRunLedger(
            plan: plan,
            sessionID: sessionID,
            listenerInstanceID: listenerID
        )

        #expect(throws: CertificationControllerError.self) {
            try ledger.append(Self.evidence(
                plan: plan,
                slot: plan.slots[0],
                ordinal: 0,
                sessionID: replacement,
                listenerID: listenerID
            ))
        }
        #expect(throws: CertificationControllerError.self) {
            try ledger.validatedReceipts()
        }
    }

    @Test
    func `ledger opens final bounds only after every non-final slot`() throws {
        let plan = try CertificationControllerPlan.decode(ControllerPlanTests.validPlanData)
        let sessionID = try #require(UUID(uuidString: "019c0000-0000-4000-8000-000000000010"))
        let listenerID = try #require(UUID(uuidString: "019c0000-0000-4000-8000-000000000011"))
        var ledger = CertificationRunLedger(
            plan: plan,
            sessionID: sessionID,
            listenerInstanceID: listenerID
        )

        for (ordinal, slot) in plan.slots.dropLast().enumerated() {
            if ordinal < 2 {
                #expect(throws: CertificationControllerError.self) {
                    try ledger.finalBoundsReadySlotIDs()
                }
            }
            try ledger.append(Self.evidence(
                plan: plan,
                slot: slot,
                ordinal: ordinal,
                sessionID: sessionID,
                listenerID: listenerID
            ))
        }

        #expect(try ledger.finalBoundsReadySlotIDs() == plan.slots.dropLast().map(\.id))
        #expect(throws: CertificationControllerError.self) {
            try ledger.validatedReceipts()
        }
    }

    private static func evidence(
        plan: CertificationControllerPlan,
        slot: CertificationSlot,
        ordinal: Int,
        sessionID: UUID,
        listenerID: UUID
    ) -> VerifiedCertificationSlot {
        let requestID = UUID()
        return VerifiedCertificationSlot(
            template: slot,
            marker: plan.marker(for: slot),
            requestID: requestID,
            sessionID: sessionID,
            sessionSequence: UInt64(ordinal),
            listenerInstanceID: listenerID,
            target: CertificationWindowReceipt(target: plan.target),
            interval: .init(startedAtMilliseconds: 100 + Int64(ordinal), completedAtMilliseconds: 101 + Int64(ordinal)),
            controllerInterval: .init(
                startedAtMilliseconds: 99 + Int64(ordinal),
                completedAtMilliseconds: 102 + Int64(ordinal)
            ),
            outcome: nil,
            result: .init(
                status: "passed",
                totalCharacters: nil,
                keyPresses: nil,
                observationFile: nil,
                observationSHA256: nil,
                observedBounds: nil
            ),
            bundle: .init(
                file: "bundles/\(requestID.uuidString.lowercased()).json",
                sha256: String(repeating: "a", count: 64),
                requestSHA256: String(repeating: "b", count: 64),
                responseSHA256: String(repeating: "c", count: 64)
            )
        )
    }
}
