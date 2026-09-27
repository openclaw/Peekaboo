import AppKit
import Foundation
import os
import PeekabooFoundation
import UniformTypeIdentifiers
import XCTest
@testable import PeekabooAutomationKit

@MainActor
final class ClipboardReadAccessTests: XCTestCase {
    func testStatusEncodingDistinguishesPolicyAvailabilityFromLegacyAdmission() throws {
        let cases: [(ClipboardReadAccessStatus.Policy, Bool, Bool)] = [
            (.systemDefault, true, false), (.ask, true, false), (.alwaysAllow, true, true),
            (.alwaysDeny, true, false), (.unknown, true, false),
            (.notRequired, false, true), (.unavailableOnOS, false, true),
        ]
        for (policy, available, admitted) in cases {
            let data = try JSONEncoder().encode(ClipboardReadAccessStatus(policy: policy))
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let fields = try decoder.decode(StatusFields.self, from: data)
            XCTAssertEqual(fields.policy, policy.rawValue)
            XCTAssertEqual(fields.policyAvailable, available)
            XCTAssertEqual(fields.readAdmitted, admitted)
            XCTAssertEqual(fields.readerContext, "caller_local")
            XCTAssertFalse(fields.contentsRead)
        }
    }

    func testExplicitManualPromptOptInDoesNotChangeSubsequentSilentReadAdmission() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let slot = NSPasteboard(name: .init("\(pasteboard.name.rawValue).boo.peekaboo.clipboard.slot.manual"))
        defer { pasteboard.releaseGlobally(); slot.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("synthetic manual read", forType: .string))
        let service = ClipboardService(pasteboard: pasteboard, readAccessStatusReader: { _ in .init(policy: .ask) })

        let read = try service.get(prefer: nil, allowPrompt: true)
        try service.save(slot: "manual", allowPrompt: true)

        XCTAssertEqual(read?.textPreview, "synthetic manual read")
        XCTAssertEqual(slot.string(forType: .string), "synthetic manual read")
        XCTAssertEqual(service.readAccessStatus().policy, .ask)
        XCTAssertThrowsError(try service.get(prefer: nil))
        XCTAssertThrowsError(try service.save(slot: "manual"))
        XCTAssertThrowsError(try service.prepareTemporaryWrite())
    }

    func testCleanupDoesNotNeedReadPermissionAgainAndStillPreservesNewerWrites() throws {
        for newerWrite in [false, true] {
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.setString("synthetic prior", forType: .string))
            var policy = ClipboardReadAccessStatus.Policy.alwaysAllow
            var policyReads = 0
            let service = ClipboardService(pasteboard: pasteboard, readAccessStatusReader: { _ in
                policyReads += 1
                return .init(policy: policy)
            })
            let transaction = try service.prepareTemporaryWrite()
            _ = try transaction.write(ClipboardPayloadBuilder.textRequest(text: "synthetic temporary"))
            let readsBeforeCleanup = policyReads
            policy = .alwaysDeny
            if newerWrite {
                pasteboard.clearContents()
                XCTAssertTrue(pasteboard.setString("synthetic newer", forType: .string))
            }

            let cleanup = try transaction.cleanup()

            XCTAssertEqual(cleanup.status, newerWrite ? .preservedNewerContents : .restored)
            XCTAssertEqual(policyReads, readsBeforeCleanup)
            XCTAssertEqual(pasteboard.string(forType: .string), newerWrite ? "synthetic newer" : "synthetic prior")
        }
    }

    func testDeniedGetAndSaveRefuseBeforeMaterializingContentsOrWritingSlots() throws {
        for policy in [ClipboardReadAccessStatus.Policy.systemDefault, .ask, .alwaysDeny, .unknown] {
            for save in [false, true] {
                let pasteboard = NSPasteboard.withUniqueName()
                let slot = NSPasteboard(name: .init("\(pasteboard.name.rawValue).boo.peekaboo.clipboard.slot.proof"))
                defer { pasteboard.releaseGlobally(); slot.releaseGlobally() }
                let provider = ReadAccessDataProvider()
                let item = NSPasteboardItem()
                XCTAssertTrue(item.setDataProvider(provider, forTypes: [.string]))
                pasteboard.clearContents()
                XCTAssertTrue(pasteboard.writeObjects([item]))
                let initialGeneration = pasteboard.changeCount
                let initialReads = provider.readCount
                var policyReads = 0
                let service = ClipboardService(pasteboard: pasteboard, readAccessStatusReader: { _ in
                    policyReads += 1
                    return .init(policy: policy)
                })

                XCTAssertThrowsError(try self.read(service, save: save)) { error in
                    guard let failure = error as? DesktopActionFailure else {
                        return XCTFail("Expected canonical permission refusal, got \(error)")
                    }
                    XCTAssertEqual(failure.outcome, .refused(reason: .permissionDenied))
                }
                XCTAssertEqual(policyReads, 1)
                XCTAssertEqual(provider.readCount, initialReads)
                XCTAssertEqual(pasteboard.changeCount, initialGeneration)
                XCTAssertTrue(slot.types?.isEmpty != false)
                withExtendedLifetime(provider) {}
            }
        }
    }

    func testPolicyStatusDoesNotMaterializeContentsOrChangeGeneration() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let provider = ReadAccessDataProvider()
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [.string]))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let initialGeneration = pasteboard.changeCount
        let initialReads = provider.readCount
        let service = ClipboardService(pasteboard: pasteboard, readAccessStatusReader: { _ in .init(policy: .ask) })

        let observation = service.readAccessStatus()

        XCTAssertEqual(observation.policy, .ask)
        XCTAssertTrue(observation.policyAvailable)
        XCTAssertFalse(observation.readAdmitted)
        XCTAssertEqual(provider.readCount, initialReads)
        XCTAssertEqual(pasteboard.changeCount, initialGeneration)
        withExtendedLifetime(provider) {}
    }

    func testWritesRemainRetryUnsafeWithoutImplicitReadbackPermission() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var policy = ClipboardReadAccessStatus.Policy.alwaysAllow
        var policyReads = 0
        let service = ClipboardService(pasteboard: pasteboard, readAccessStatusReader: { _ in
            policyReads += 1
            return .init(policy: policy)
        })
        let request = try ClipboardPayloadBuilder.textRequest(text: "synthetic original")
        _ = try service.set(request)
        try service.save(slot: "proof")
        policy = .ask
        policyReads = 0

        let set = try service.setActionResult(ClipboardPayloadBuilder.textRequest(text: "synthetic temporary"))
        let restore = try service.restoreActionResult(slot: "proof")
        let clear = try service.clearActionResult()

        for reported in [set.outcome, restore.outcome, clear.outcome] {
            let outcome = try XCTUnwrap(reported)
            XCTAssertEqual(outcome.state, .dispatchedUnverified)
            XCTAssertTrue(outcome.dispatchState.mutationDispatched)
            XCTAssertEqual(outcome.retrySafety, .unsafe)
        }
        XCTAssertEqual(policyReads, 3)
    }

    private func read(_ service: ClipboardService, save: Bool) throws {
        if save {
            try service.save(slot: "proof")
        } else {
            _ = try service.get(prefer: nil)
        }
    }
}

private struct StatusFields: Decodable {
    let policy: String
    let policyAvailable: Bool
    let readAdmitted: Bool
    let readerContext: String
    let contentsRead: Bool
}

private final class ReadAccessDataProvider: NSObject, NSPasteboardItemDataProvider {
    private let reads = OSAllocatedUnfairLock(initialState: 0)

    var readCount: Int {
        self.reads.withLock { $0 }
    }

    func pasteboard(_: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        self.reads.withLock { $0 += 1 }
        item.setString("synthetic promised contents", forType: type)
    }
}
