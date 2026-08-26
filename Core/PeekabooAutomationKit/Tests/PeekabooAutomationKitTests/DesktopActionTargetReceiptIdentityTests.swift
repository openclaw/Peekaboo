import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct DesktopActionTargetReceiptIdentityTests {
    private static let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)

    @Test
    func `identity projections preserve legacy receipt bytes`() throws {
        let process = ApplicationProcessIdentity(
            processIdentifier: 42,
            processStartIdentity: 9_007_199_254_740_993)
        let processReceipt = DesktopActionTargetReceipt(
            processIdentifier: process.processIdentifier,
            processStartIdentity: process.processStartIdentity)
        try self.expectByteParity(process.actionTargetReceipt, processReceipt)

        let windowIdentity = WindowMutationIdentity(
            windowID: 71,
            ownerProcessIdentifier: process.processIdentifier,
            ownerProcessStartIdentity: process.processStartIdentity,
            capturedBounds: Self.bounds,
            isMinimized: true)
        let windowReceipt = DesktopActionTargetReceipt(
            processIdentifier: windowIdentity.ownerProcessIdentifier,
            processStartIdentity: windowIdentity.ownerProcessStartIdentity,
            windowID: windowIdentity.windowID)
        try self.expectByteParity(windowIdentity.actionTargetReceipt, windowReceipt)
        try self.expectByteParity(#require(windowIdentity.validActionTargetReceipt), windowReceipt)

        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: windowIdentity,
            bounds: Self.bounds)
        try self.expectByteParity(exactWindow.actionTargetReceipt, windowReceipt)

        let processTarget = try DesktopTargetIdentity(processIdentity: process)
        try self.expectByteParity(processTarget.actionTargetReceipt, processReceipt)

        let windowTarget = DesktopTargetIdentity(exactWindow: exactWindow)
        try self.expectByteParity(windowTarget.actionTargetReceipt, windowReceipt)
    }

    @Test
    func `exact window receipt takes precedence over its process receipt`() throws {
        let process = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 1001)
        let processTarget = try DesktopTargetIdentity(processIdentity: process)
        #expect(processTarget.actionTargetReceipt == DesktopActionTargetReceipt(
            processIdentifier: 42,
            processStartIdentity: 1001))

        let windowIdentity = WindowMutationIdentity(
            windowID: 71,
            ownerProcessIdentifier: process.processIdentifier,
            ownerProcessStartIdentity: process.processStartIdentity,
            capturedBounds: Self.bounds)
        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: windowIdentity,
            bounds: Self.bounds)
        let windowTarget = DesktopTargetIdentity(exactWindow: exactWindow)

        #expect(windowTarget.processIdentity == process)
        #expect(windowTarget.actionTargetReceipt == DesktopActionTargetReceipt(
            processIdentifier: 42,
            processStartIdentity: 1001,
            windowID: 71))
    }

    @Test
    func `valid window receipt rejects invalid identity fields and window IDs`() throws {
        let aboveWindowServerRange = try #require(Int(exactly: UInt64(UInt32.max) + 1))
        let invalidIdentities = [
            WindowMutationIdentity(
                windowID: 71,
                ownerProcessIdentifier: 0,
                ownerProcessStartIdentity: 1001),
            WindowMutationIdentity(
                windowID: 71,
                ownerProcessIdentifier: -1,
                ownerProcessStartIdentity: 1001),
            WindowMutationIdentity(
                windowID: 71,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 0),
            WindowMutationIdentity(
                windowID: 0,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 1001),
            WindowMutationIdentity(
                windowID: -1,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 1001),
            WindowMutationIdentity(
                windowID: aboveWindowServerRange,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 1001),
        ]

        for identity in invalidIdentities {
            #expect(identity.validActionTargetReceipt == nil)
            let legacyReceipt = DesktopActionTargetReceipt(
                processIdentifier: identity.ownerProcessIdentifier,
                processStartIdentity: identity.ownerProcessStartIdentity,
                windowID: identity.windowID)
            try self.expectByteParity(identity.actionTargetReceipt, legacyReceipt)
        }
    }

    @Test
    func `valid receipt ignores mutable window metadata`() throws {
        let identity = WindowMutationIdentity(
            windowID: Int(UInt32.max),
            ownerProcessIdentifier: Int32.max,
            ownerProcessStartIdentity: UInt64.max,
            capturedBounds: Self.bounds,
            isMinimized: false)
        let changedMetadata = WindowMutationIdentity(
            windowID: identity.windowID,
            ownerProcessIdentifier: identity.ownerProcessIdentifier,
            ownerProcessStartIdentity: identity.ownerProcessStartIdentity,
            capturedBounds: nil,
            isMinimized: true)

        let receipt = try #require(identity.validActionTargetReceipt)
        #expect(changedMetadata.validActionTargetReceipt == receipt)
        try self.expectByteParity(changedMetadata.actionTargetReceipt, receipt)
    }

    private func expectByteParity(
        _ projected: DesktopActionTargetReceipt,
        _ legacy: DesktopActionTargetReceipt) throws
    {
        #expect(projected == legacy)
        #expect(try self.encoded(projected) == self.encoded(legacy))
    }

    private func encoded(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
