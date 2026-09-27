import AppKit
import Foundation
import PeekabooFoundation
import XCTest
@testable import PeekabooAutomationKit

@MainActor
final class ClipboardTemporaryWriteTests: XCTestCase {
    func testClaimedSetupFailureIsLocalRetryUnsafeAndKeepsItsErrorCode() {
        let refusal = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .targetUnavailable,
            message: "Synthetic validation error after a clipboard claim",
            standardErrorCode: .timeout)
        let failure = ClipboardTemporaryWriteFailure.make(
            refusal,
            didMutate: true,
            cleanupStatus: .preservedNewerContents)

        XCTAssertEqual(failure.outcome.route, .local)
        XCTAssertEqual(failure.outcome.delivery, ClipboardMutationResultSemantics.delivery)
        XCTAssertEqual(failure.outcome.state, .indeterminate)
        XCTAssertEqual(failure.outcome.retrySafety, .unsafe)
        XCTAssertNil(failure.outcome.dispatchState.unitCount)
        XCTAssertNil(failure.targetReceipt)
        XCTAssertEqual(failure.standardErrorCode, .timeout)
        XCTAssertTrue(failure.message.contains("newer clipboard update was preserved"))
        XCTAssertTrue(failure.hint?.contains("no paste input was sent") == true)
    }

    func testNoClaimSetupFailureStaysRetrySafeWithZeroDispatch() {
        let failure = ClipboardTemporaryWriteFailure.make(
            ClipboardServiceError.writeFailed("Synthetic rejected request"),
            didMutate: false,
            cleanupStatus: .notNeeded)

        XCTAssertEqual(failure.outcome.state, .refused)
        XCTAssertEqual(failure.outcome.dispatchState, .none)
        XCTAssertEqual(failure.outcome.retrySafety, .safe)
    }

    func testReportedPartialSetupFailureKeepsActualDispatchCount() {
        let reported = DesktopActionFailure.partial(
            delivery: ClipboardMutationResultSemantics.delivery,
            unitCount: DesktopActionOutcome.DispatchUnitCount(3),
            message: "Synthetic partial write")
        let failure = ClipboardTemporaryWriteFailure.make(
            reported,
            didMutate: true,
            cleanupStatus: .preservedNewerContents)

        XCTAssertEqual(failure.outcome, reported.outcome)
        XCTAssertEqual(failure.outcome.dispatchState.unitCount?.rawValue, 3)
    }

    func testOwnedCleanupRestoresPopulatedAndEmptyPriorStateOnce() throws {
        for prior in [nil, Self.payload("prior")] {
            let fixture = Fixture(prior: prior)
            let transaction = fixture.transaction()
            XCTAssertEqual(transaction.priorClipboardPresent, prior != nil)
            XCTAssertFalse(transaction.didMutate)
            _ = try transaction.write(Self.request("temporary"))
            XCTAssertTrue(transaction.didMutate)

            for _ in 0..<2 {
                guard case let .restored(restored) = try transaction.cleanup() else {
                    return XCTFail("Expected restoration")
                }
                XCTAssertEqual(restored?.data, prior?.data)
            }
            XCTAssertEqual(fixture.current?.data, prior?.data)
            XCTAssertEqual(fixture.restoreCalls, 1)
        }
    }

    func testNewGenerationIsPreservedEvenWhenItsBytesMatchTemporaryPayload() throws {
        for prior in [nil, Self.payload("prior")] {
            for newerText in ["newer", "temporary"] {
                let fixture = Fixture(prior: prior)
                let transaction = fixture.transaction()
                _ = try transaction.write(Self.request("temporary"))
                fixture.externalWrite(Self.payload(newerText))
                let newerGeneration = fixture.generation

                for _ in 0..<2 {
                    guard case .preservedNewerContents = try transaction.cleanup() else {
                        return XCTFail("Expected the external generation to survive")
                    }
                }
                XCTAssertEqual(fixture.current?.data, Data(newerText.utf8))
                XCTAssertEqual(fixture.generation, newerGeneration)
                XCTAssertEqual(fixture.restoreCalls, 0)
            }
        }
    }

    func testChangedSnapshotRefusesBeforeClaim() throws {
        let fixture = Fixture(prior: Self.payload("prior"))
        let transaction = fixture.transaction()
        fixture.externalWrite(Self.payload("newer"))

        XCTAssertThrowsError(try transaction.write(Self.request("temporary"))) { error in
            guard case ClipboardTemporaryWriteError.snapshotChanged = error else {
                return XCTFail("Expected changed snapshot, got \(error)")
            }
        }
        XCTAssertFalse(transaction.didMutate)
        XCTAssertEqual(fixture.writeCalls, 0)
        guard case .notNeeded = try transaction.cleanup() else { return XCTFail("Expected no cleanup") }
        XCTAssertEqual(fixture.restoreCalls, 0)
        XCTAssertEqual(fixture.current?.data, Data("newer".utf8))
    }

    func testPreclaimFailureDoesNotRestoreOrClear() throws {
        let fixture = Fixture(prior: nil)
        fixture.failBeforeClaim = true
        let transaction = fixture.transaction()

        XCTAssertThrowsError(try transaction.write(Self.request("temporary")))
        XCTAssertFalse(transaction.didMutate)
        guard case .notNeeded = try transaction.cleanup() else { return XCTFail("Expected no cleanup") }
        XCTAssertEqual(fixture.restoreCalls, 0)
        XCTAssertNil(fixture.current)
    }

    func testPartialWriteRetainsClaimAndRestoresWithoutAnotherWriteAttempt() throws {
        let fixture = Fixture(prior: Self.payload("prior"))
        fixture.failAfterClaim = true
        let transaction = fixture.transaction()

        XCTAssertThrowsError(try transaction.write(Self.request("temporary")))
        XCTAssertTrue(transaction.didMutate)
        guard case let .restored(restored) = try transaction.cleanup() else {
            return XCTFail("Expected owned partial-write cleanup")
        }
        XCTAssertEqual(restored?.data, Data("prior".utf8))
        XCTAssertEqual(fixture.writeCalls, 1)
        XCTAssertEqual(fixture.restoreCalls, 1)
        XCTAssertThrowsError(try transaction.write(Self.request("replay")))
        XCTAssertEqual(fixture.writeCalls, 1)
    }

    func testSupersededPartialWriteNeverAdoptsTheNewerGeneration() throws {
        let fixture = Fixture(prior: Self.payload("prior"))
        fixture.failAfterClaim = true
        fixture.externalWriteAfterClaim = Self.payload("newer")
        let transaction = fixture.transaction()

        XCTAssertThrowsError(try transaction.write(Self.request("temporary")))
        XCTAssertTrue(transaction.didMutate)
        guard case .preservedNewerContents = try transaction.cleanup() else {
            return XCTFail("Expected newer contents to survive partial-write cleanup")
        }
        XCTAssertEqual(fixture.current?.data, Data("newer".utf8))
        XCTAssertEqual(fixture.restoreCalls, 0)
    }

    func testSuccessfulWriteReturningAfterSupersessionIsNotAccepted() throws {
        let fixture = Fixture(prior: Self.payload("prior"))
        fixture.externalWriteAfterClaim = Self.payload("newer")
        let transaction = fixture.transaction()

        XCTAssertThrowsError(try transaction.write(Self.request("temporary"))) { error in
            guard case ClipboardTemporaryWriteError.ownershipChanged = error else {
                return XCTFail("Expected ownership loss, got \(error)")
            }
        }
        guard case .preservedNewerContents = try transaction.cleanup() else {
            return XCTFail("Expected newer contents to survive")
        }
        XCTAssertEqual(fixture.restoreCalls, 0)
    }

    func testOwnershipChangeInsideCleanupDoesNotClaimRestoration() throws {
        let fixture = Fixture(prior: Self.payload("prior"))
        fixture.externalWriteDuringRestore = Self.payload("newer")
        let transaction = fixture.transaction()
        _ = try transaction.write(Self.request("temporary"))

        guard case .preservedNewerContents = try transaction.cleanup() else {
            return XCTFail("Expected native cleanup ownership loss")
        }
        XCTAssertEqual(fixture.current?.data, Data("newer".utf8))
        XCTAssertEqual(fixture.restoreCalls, 1)
        _ = try transaction.cleanup()
        XCTAssertEqual(fixture.restoreCalls, 1)
    }

    func testRealCleanupFailureIsRetainedWithoutRetrying() throws {
        let fixture = Fixture(prior: Self.payload("prior"))
        fixture.failRestore = true
        let transaction = fixture.transaction()
        _ = try transaction.write(Self.request("temporary"))

        for _ in 0..<2 {
            XCTAssertThrowsError(try transaction.cleanup()) { error in
                XCTAssertEqual(error as? Fixture.Failure, .restore)
            }
        }
        XCTAssertEqual(fixture.restoreCalls, 1)
        XCTAssertTrue(transaction.didMutate)
    }

    func testCleanupBeforeWriteEndsTheTransactionWithoutMutation() throws {
        let fixture = Fixture(prior: Self.payload("prior"))
        let transaction = fixture.transaction()
        guard case .notNeeded = try transaction.cleanup() else { return XCTFail("Expected no cleanup") }

        XCTAssertThrowsError(try transaction.write(Self.request("temporary")))
        XCTAssertEqual(fixture.writeCalls, 0)
        XCTAssertEqual(fixture.restoreCalls, 0)
        XCTAssertFalse(transaction.didMutate)
    }

    func testTemporaryReadAccessRequiresSilentGeneralPermissionWithoutInspectingContents() throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("Pasteboard access policy requires macOS 15.4") }
        let modes: [NSPasteboard.AccessBehavior] = [.default, .ask, .alwaysAllow, .alwaysDeny]
        for mode in modes {
            XCTAssertNoThrow(try ClipboardService.requireSilentReadAccess(ClipboardService.readAccessStatus(
                pasteboardName: NSPasteboard.Name("synthetic.private.board"),
                accessBehavior: mode)))
            if mode == .alwaysAllow {
                XCTAssertNoThrow(try ClipboardService.requireSilentReadAccess(ClipboardService.readAccessStatus(
                    pasteboardName: .general, accessBehavior: mode)))
            } else {
                XCTAssertThrowsError(try ClipboardService.requireSilentReadAccess(ClipboardService.readAccessStatus(
                    pasteboardName: .general, accessBehavior: mode)))
                { error in
                    guard let failure = error as? DesktopActionFailure else {
                        return XCTFail("Expected a canonical permission refusal")
                    }
                    XCTAssertEqual(failure.outcome.refusalReason, .permissionDenied)
                    XCTAssertFalse(failure.outcome.dispatchState.mutationDispatched)
                    XCTAssertEqual(failure.outcome.retrySafety, .safe)
                }
            }
        }
    }

    func testNativeLazyRepresentationIsMaterializedAndRestored() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let type = NSPasteboard.PasteboardType("synthetic.clipboard.lazy")
        let bytes = Data("promised contents".utf8)
        let provider = TemporaryPasteboardDataProvider(data: bytes)
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [type]))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let generation = pasteboard.changeCount

        let transaction = try ClipboardService(pasteboard: pasteboard).prepareTemporaryWrite()
        XCTAssertEqual(pasteboard.changeCount, generation)
        _ = try transaction.write(Self.request("temporary"))
        guard case .restored = try transaction.cleanup() else { return XCTFail("Expected restoration") }
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.data(forType: type), bytes)
        withExtendedLifetime(provider) {}
    }

    func testNativeUnresolvedRepresentationRefusesWithoutDiscardingReadableCompanion() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let type = NSPasteboard.PasteboardType("synthetic.clipboard.unresolved")
        let provider = TemporaryPasteboardDataProvider(data: nil)
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString("prior readable text", forType: .string))
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [type]))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let original = try XCTUnwrap(pasteboard.pasteboardItems?.first)
        let originalTypes = original.types
        XCTAssertTrue(originalTypes.contains(type))
        XCTAssertNil(original.data(forType: type))
        let generation = pasteboard.changeCount

        XCTAssertThrowsError(try ClipboardService(pasteboard: pasteboard).prepareTemporaryWrite()) { error in
            guard case ClipboardTemporaryWriteError.snapshotUnavailable = error else {
                return XCTFail("Expected an unavailable complete snapshot")
            }
        }
        XCTAssertEqual(pasteboard.changeCount, generation)
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.types, originalTypes)
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.string(forType: .string), "prior readable text")
        XCTAssertNil(pasteboard.pasteboardItems?.first?.data(forType: type))
        withExtendedLifetime(provider) {}
    }

    func testNativeEmptyMarkerDataIsPreservedRatherThanTreatedAsUnavailable() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let type = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString("prior", forType: .string))
        XCTAssertTrue(item.setData(Data(), forType: type))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let transaction = try ClipboardService(pasteboard: pasteboard).prepareTemporaryWrite()
        _ = try transaction.write(Self.request("temporary"))
        guard case .restored = try transaction.cleanup() else { return XCTFail("Expected restoration") }
        let restored = try XCTUnwrap(pasteboard.pasteboardItems?.first)
        XCTAssertTrue(restored.types.contains(type))
        XCTAssertEqual(restored.data(forType: type), Data())
        XCTAssertEqual(restored.string(forType: .string), "prior")
    }

    func testNativeEmptySnapshotIsReadOnlyAndRestoresEmpty() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let clipboard = ClipboardService(pasteboard: pasteboard)
        let originalGeneration = pasteboard.changeCount
        let transaction = try clipboard.prepareTemporaryWrite()

        XCTAssertFalse(transaction.priorClipboardPresent)
        XCTAssertEqual(pasteboard.changeCount, originalGeneration)
        _ = try transaction.write(Self.request("temporary"))
        guard case let .restored(restored) = try transaction.cleanup() else {
            return XCTFail("Expected empty restoration")
        }
        XCTAssertNil(restored)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 0)
        XCTAssertEqual(pasteboard.types?.count, 0)
    }

    func testNativeRestorationPreservesOrderedItemsAndEveryRepresentation() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let customType = NSPasteboard.PasteboardType("synthetic.clipboard.bytes")
        let first = NSPasteboardItem()
        XCTAssertTrue(first.setData(Data([0x00, 0x01, 0xFF]), forType: customType))
        XCTAssertTrue(first.setString("first", forType: .string))
        let second = NSPasteboardItem()
        XCTAssertTrue(second.setString("second", forType: .string))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([first, second]))
        let originalItems = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(originalItems.count, 2)
        guard originalItems.count == 2 else { return }
        let originalFirstTypes = originalItems[0].types
        let originalSecondTypes = originalItems[1].types
        let originalGeneration = pasteboard.changeCount
        let transaction = try ClipboardService(pasteboard: pasteboard).prepareTemporaryWrite()
        XCTAssertEqual(pasteboard.changeCount, originalGeneration)

        _ = try transaction.write(Self.request("temporary"))
        guard case .restored = try transaction.cleanup() else { return XCTFail("Expected restoration") }
        let restored = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(restored.count, 2)
        guard restored.count == 2 else { return }
        XCTAssertEqual(restored[0].types, originalFirstTypes)
        XCTAssertEqual(restored[0].data(forType: customType), Data([0x00, 0x01, 0xFF]))
        XCTAssertEqual(restored[0].string(forType: .string), "first")
        XCTAssertEqual(restored[1].types, originalSecondTypes)
        XCTAssertEqual(restored[1].string(forType: .string), "second")
    }

    func testNativeNewOwnerWithIdenticalPayloadIsPreserved() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = ClipboardService(pasteboard: pasteboard)
        _ = try clipboard.set(Self.request("prior"))
        let transaction = try clipboard.prepareTemporaryWrite()
        _ = try transaction.write(Self.request("temporary"))
        let externalClipboard = ClipboardService(pasteboard: NSPasteboard(name: pasteboard.name))
        _ = try externalClipboard.set(Self.request("temporary"))
        let newerGeneration = pasteboard.changeCount

        guard case .preservedNewerContents = try transaction.cleanup() else {
            return XCTFail("Expected the external ownership claim to survive")
        }
        XCTAssertEqual(pasteboard.changeCount, newerGeneration)
        XCTAssertEqual(try clipboard.get(prefer: nil)?.data, Data("temporary".utf8))
    }

    func testNativeInvalidPayloadDoesNotClaimOrCleanUp() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = ClipboardService(pasteboard: pasteboard)
        _ = try clipboard.set(Self.request("prior"))
        let transaction = try clipboard.prepareTemporaryWrite()
        let originalGeneration = pasteboard.changeCount

        XCTAssertThrowsError(try transaction.write(ClipboardWriteRequest(representations: [])))
        XCTAssertFalse(transaction.didMutate)
        guard case .notNeeded = try transaction.cleanup() else { return XCTFail("Expected no cleanup") }
        XCTAssertEqual(pasteboard.changeCount, originalGeneration)
        XCTAssertEqual(try clipboard.get(prefer: nil)?.data, Data("prior".utf8))
    }

    func testNativeTextAndBinaryCompanionWritesRetainTheirDeclarationClaim() throws {
        let requests = try [
            ClipboardPayloadBuilder.textRequest(text: "synthetic-élan"),
            ClipboardWriteRequest(
                representations: [ClipboardRepresentation(utiIdentifier: "public.data", data: Data([0x01]))],
                alsoText: "synthetic companion"),
        ]
        for request in requests {
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let clipboard = ClipboardService(pasteboard: pasteboard)
            _ = try clipboard.set(Self.request("prior"))
            let transaction = try clipboard.prepareTemporaryWrite()

            _ = try transaction.write(request)
            XCTAssertTrue(transaction.didMutate)
            guard case .restored = try transaction.cleanup() else { return XCTFail("Expected owned restoration") }
            XCTAssertEqual(try clipboard.get(prefer: nil)?.data, Data("prior".utf8))
        }
    }

    private static func payload(_ text: String) -> ClipboardReadResult {
        ClipboardReadResult(utiIdentifier: "public.data", data: Data(text.utf8), textPreview: nil)
    }

    private static func request(_ text: String) -> ClipboardWriteRequest {
        ClipboardWriteRequest(representations: [
            ClipboardRepresentation(utiIdentifier: "public.data", data: Data(text.utf8)),
        ])
    }

    @MainActor
    private final class Fixture {
        enum Failure: Error, Equatable {
            case beforeClaim
            case partialWrite
            case restore
        }

        let prior: ClipboardReadResult?
        var current: ClipboardReadResult?
        var generation = 10
        var failBeforeClaim = false
        var failAfterClaim = false
        var failRestore = false
        var externalWriteAfterClaim: ClipboardReadResult?
        var externalWriteDuringRestore: ClipboardReadResult?
        private(set) var writeCalls = 0
        private(set) var restoreCalls = 0

        init(prior: ClipboardReadResult?) {
            self.prior = prior
            self.current = prior
        }

        func transaction() -> OwnedClipboardTemporaryWriteTransaction {
            OwnedClipboardTemporaryWriteTransaction(
                priorClipboardPresent: self.prior != nil,
                originalChangeCount: self.generation,
                access: ClipboardTemporaryWriteAccess(
                    changeCount: { self.generation },
                    write: { request, expected, didClaim in
                        self.writeCalls += 1
                        if self.failBeforeClaim {
                            throw Failure.beforeClaim
                        }
                        guard self.generation == expected else {
                            throw ClipboardTemporaryWriteError.ownershipChanged
                        }
                        self.generation += 1
                        didClaim(self.generation)
                        let primary = request.representations[0]
                        let result = ClipboardReadResult(
                            utiIdentifier: primary.utiIdentifier, data: primary.data, textPreview: nil)
                        self.current = result
                        if let newer = self.externalWriteAfterClaim {
                            self.externalWrite(newer)
                        }
                        if self.failAfterClaim {
                            throw Failure.partialWrite
                        }
                        return result
                    },
                    restore: { expected in
                        self.restoreCalls += 1
                        if let newer = self.externalWriteDuringRestore {
                            self.externalWrite(newer)
                        }
                        guard self.generation == expected else {
                            throw ClipboardTemporaryWriteError.ownershipChanged
                        }
                        if self.failRestore {
                            throw Failure.restore
                        }
                        self.generation += 1
                        self.current = self.prior
                        return self.prior
                    }))
        }

        func externalWrite(_ value: ClipboardReadResult) {
            self.generation += 1
            self.current = value
        }
    }
}

private final class TemporaryPasteboardDataProvider: NSObject, NSPasteboardItemDataProvider {
    let data: Data?

    init(data: Data?) {
        self.data = data
    }

    func pasteboard(_: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if let data {
            item.setData(data, forType: type)
        }
    }
}
