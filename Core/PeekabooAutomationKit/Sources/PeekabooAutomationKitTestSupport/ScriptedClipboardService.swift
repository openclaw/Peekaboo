import Foundation
@_spi(Testing) import PeekabooAutomationKit
import UniformTypeIdentifiers

/// In-memory pasteboard with the production temporary-write ownership state machine.
@MainActor
open class ScriptedClipboardService: ClipboardTemporaryWriteProviding, ClipboardReadAccessProviding {
    public var readAccess = ClipboardReadAccessStatus(policy: .alwaysAllow)
    public private(set) var readAccessStatusCallCount = 0
    public private(set) var readPromptOptions: [Bool] = []
    public private(set) var savePromptOptions: [Bool] = []
    public var current: ClipboardReadResult? {
        didSet { self.generation += 1 }
    }

    public var slots: [String: ClipboardReadResult] = [:]
    public var beforeMutation: (() -> Void)?
    public var afterSave: (() -> Void)?
    public var afterSet: (() -> Void)?
    public var afterPartialSet: (() -> Void)?
    public var getError: (any Error)?
    public var saveError: (any Error)?
    public var setError: (any Error)?
    public var setMutatesBeforeThrow = false
    public var restoreError: (any Error)?
    public private(set) var getCallCount = 0
    public private(set) var setCallCount = 0
    public private(set) var clearCallCount = 0
    public private(set) var saveCallCount = 0
    public private(set) var restoreCallCount = 0
    public var retainsTemporaryWriteClaims = true

    private var generation = 0

    public init(current: ClipboardReadResult? = nil, restoreError: (any Error)? = nil) {
        self.current = current
        self.restoreError = restoreError
    }

    public func readAccessStatus() -> ClipboardReadAccessStatus {
        self.readAccessStatusCallCount += 1
        return self.readAccess
    }

    public func get(prefer uti: UTType?, allowPrompt: Bool) throws -> ClipboardReadResult? {
        self.readPromptOptions.append(allowPrompt)
        return try self.get(prefer: uti)
    }

    public func save(slot: String, allowPrompt: Bool) throws {
        self.savePromptOptions.append(allowPrompt)
        try self.save(slot: slot)
    }

    open func get(prefer _: UTType?) throws -> ClipboardReadResult? {
        self.getCallCount += 1
        if let getError {
            throw getError
        }
        return self.current
    }

    open func set(_ request: ClipboardWriteRequest) throws -> ClipboardReadResult {
        try self.performSet(request, didClaim: { _ in })
    }

    private func performSet(
        _ request: ClipboardWriteRequest,
        expectedGeneration: Int? = nil,
        didClaim: (Int) -> Void) throws -> ClipboardReadResult
    {
        self.beforeMutation?()
        if let expectedGeneration, self.generation != expectedGeneration {
            throw ClipboardTemporaryWriteError.ownershipChanged
        }
        self.setCallCount += 1
        guard let primary = request.representations.first else {
            throw ClipboardServiceError.writeFailed("No representations provided")
        }
        let result = ClipboardReadResult(
            utiIdentifier: primary.utiIdentifier,
            data: primary.data,
            textPreview: request.alsoText)
        if let setError {
            if self.setMutatesBeforeThrow {
                self.current = result
                didClaim(self.generation)
                self.afterPartialSet?()
            }
            throw setError
        }
        self.current = result
        didClaim(self.generation)
        self.afterSet?()
        return result
    }

    open func clear() {
        self.beforeMutation?()
        self.clearCallCount += 1
        self.current = nil
    }

    open func save(slot: String) throws {
        self.saveCallCount += 1
        if let saveError {
            throw saveError
        }
        guard let current else { throw ClipboardServiceError.empty }
        self.slots[slot] = current
        self.afterSave?()
    }

    open func restore(slot: String) throws -> ClipboardReadResult {
        self.beforeMutation?()
        self.restoreCallCount += 1
        if let restoreError {
            throw restoreError
        }
        guard let saved = self.slots[slot] else { throw ClipboardServiceError.slotNotFound(slot) }
        self.current = saved
        return saved
    }

    public func prepareTemporaryWrite() throws -> any ClipboardTemporaryWriteTransaction {
        let originalGeneration = self.generation
        let prior = try self.get(prefer: nil)
        let slot = "temporary-\(UUID().uuidString)"
        if prior != nil {
            try self.save(slot: slot)
        }
        let transaction = ClipboardTemporaryWriteTesting.transaction(
            priorClipboardPresent: prior != nil,
            originalChangeCount: originalGeneration,
            isGeneralPasteboard: true,
            changeCount: { self.generation },
            write: { request, expected, didClaim in
                guard self.generation == expected else { throw ClipboardTemporaryWriteError.ownershipChanged }
                return try self.performSet(request, expectedGeneration: expected, didClaim: didClaim)
            },
            restore: { expected in
                guard self.generation == expected else { throw ClipboardTemporaryWriteError.ownershipChanged }
                if prior != nil {
                    return try self.restore(slot: slot)
                }
                self.clear()
                return nil
            })
        return self.retainsTemporaryWriteClaims ? transaction : ClaimlessTemporaryWriteTransaction(transaction)
    }

    public func listSlots() -> [String] {
        Array(self.slots.keys)
    }
}

@MainActor
private final class ClaimlessTemporaryWriteTransaction: ClipboardTemporaryWriteTransaction {
    private let transaction: any ClipboardTemporaryWriteTransaction
    var priorClipboardPresent: Bool {
        self.transaction.priorClipboardPresent
    }

    var didMutate: Bool {
        self.transaction.didMutate
    }

    init(_ transaction: any ClipboardTemporaryWriteTransaction) {
        self.transaction = transaction
    }

    func write(_ request: ClipboardWriteRequest) throws -> ClipboardReadResult {
        try self.transaction.write(request)
    }

    func cleanup() throws -> ClipboardTemporaryCleanupResult {
        try self.transaction.cleanup()
    }
}
