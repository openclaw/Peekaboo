import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import PeekabooAutomationKit

struct SystemIdentityResolverTests {
    @Test
    func `full BSD observation preserves generation and distinguishes explicit denial from arbitrary failure`() {
        var info = proc_bsdinfo()
        info.pbi_start_tvsec = 123
        info.pbi_start_tvusec = 456
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let readable = SystemIdentityResolver.processStartIdentityObservation(
            info: info, bytesRead: size, errorCode: EPERM)
        #expect(readable == .identity(123_000_456))
        #expect(readable.identity == 123_000_456)

        for bytesRead in [Int32(0), -1] {
            let denied = SystemIdentityResolver.processStartIdentityObservation(
                info: info, bytesRead: bytesRead, errorCode: EPERM)
            #expect(denied == .permissionDenied)
            #expect(denied.identity == nil)
            for errorCode in [0, ESRCH, EIO, EACCES] {
                let unavailable = SystemIdentityResolver.processStartIdentityObservation(
                    info: info, bytesRead: bytesRead, errorCode: errorCode)
                #expect(unavailable == .unavailable)
                #expect(unavailable.identity == nil)
            }
        }
        for bytesRead in [size - 1, size + 1] {
            #expect(SystemIdentityResolver.processStartIdentityObservation(
                info: info, bytesRead: bytesRead, errorCode: EPERM) == .unavailable)
        }
        info.pbi_start_tvsec = UInt64.max
        info.pbi_start_tvusec = 999_999
        #expect(SystemIdentityResolver.processStartIdentityObservation(
            info: info, bytesRead: size, errorCode: 0).identity ==
            UInt64.max.multipliedReportingOverflow(by: 1_000_000).partialValue &+ 999_999)
    }

    @Test
    func `short BSD credentials require exact size and expected PID and use effective rather than real UID`() {
        var info = proc_bsdshortinfo()
        info.pbsi_pid = 42
        info.pbsi_uid = 502
        info.pbsi_ruid = 501
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.stride)
        #expect(SystemIdentityResolver.processCredentials(42, info: info, bytesRead: size) ==
            .init(processIdentifier: 42, effectiveUserID: 502))
        #expect(SystemIdentityResolver.processCredentials(43, info: info, bytesRead: size) == nil)
        #expect(SystemIdentityResolver.processCredentials(-1, info: info, bytesRead: size) == nil)
        for bytesRead in [0, -1, size - 1, size + 1] {
            #expect(SystemIdentityResolver.processCredentials(42, info: info, bytesRead: bytesRead) == nil)
        }
    }

    @Test
    func `Exact window identity can be selected from a full offscreen catalog`() throws {
        let expectedBounds = CGRect(x: 560, y: 371, width: 673, height: 439)
        let unrelated = Self.windowDictionary(
            windowID: 1789,
            ownerPID: 41,
            bounds: CGRect(x: 10, y: 20, width: 300, height: 200),
            isOnScreen: true)
        let minimized = Self.windowDictionary(
            windowID: 1790,
            ownerPID: 42,
            bounds: expectedBounds,
            isOnScreen: false)

        let identity = try #require(SystemIdentityResolver.windowIdentity(1790, in: [unrelated, minimized]))

        #expect(identity.windowID == 1790)
        #expect(identity.ownerProcessIdentifier == 42)
        #expect(identity.bounds == expectedBounds)
        #expect(identity.isOnScreen == false)
    }

    @Test
    func `Stable window identity binds generation while allowing descriptive metadata refresh`() throws {
        let before = Self.identity(title: "Before", applicationName: "Old Name")
        let after = Self.identity(title: "After", applicationName: "New Name")
        var identities = [before, after]
        var generations: [UInt64] = [111, 111]

        let identity = try #require(SystemIdentityResolver.stableWindowIdentity(
            1790,
            windowIdentityProvider: { _ in identities.removeFirst() },
            processStartIdentityProvider: { _ in generations.removeFirst() }))

        #expect(identity.ownerProcessStartIdentity == 111)
        #expect(identity.title == "After")
        #expect(identity.applicationName == "New Name")
    }

    @Test
    func `Stable window identity rejects generation and safety fingerprint drift`() {
        let before = Self.identity()
        let changedBounds = Self.identity(bounds: CGRect(x: 561, y: 371, width: 673, height: 439))
        let changedOwner = Self.identity(ownerPID: 43)

        for after in [changedBounds, changedOwner] {
            var identities = [before, after]
            var generations: [UInt64] = [111, 111]
            #expect(SystemIdentityResolver.stableWindowIdentity(
                1790,
                windowIdentityProvider: { _ in identities.removeFirst() },
                processStartIdentityProvider: { _ in generations.removeFirst() }) == nil)
        }

        var stableIdentities = [before, before]
        var changedGenerations: [UInt64] = [111, 112]
        #expect(SystemIdentityResolver.stableWindowIdentity(
            1790,
            windowIdentityProvider: { _ in stableIdentities.removeFirst() },
            processStartIdentityProvider: { _ in changedGenerations.removeFirst() }) == nil)
    }

    private static func identity(
        ownerPID: pid_t = 42,
        title: String = "Fixture",
        bounds: CGRect = CGRect(x: 560, y: 371, width: 673, height: 439),
        applicationName: String = "Fixture App") -> SystemWindowIdentity
    {
        SystemWindowIdentity(
            windowID: 1790,
            ownerProcessIdentifier: ownerPID,
            title: title,
            bounds: bounds,
            layer: 0,
            alpha: 1,
            isOnScreen: true,
            sharingState: .readWrite,
            applicationName: applicationName)
    }

    private static func windowDictionary(
        windowID: Int,
        ownerPID: Int,
        bounds: CGRect,
        isOnScreen: Bool) -> [String: Any]
    {
        [
            kCGWindowNumber as String: windowID,
            kCGWindowOwnerPID as String: ownerPID,
            kCGWindowBounds as String: bounds.dictionaryRepresentation,
            kCGWindowIsOnscreen as String: isOnScreen,
            kCGWindowLayer as String: 0,
            kCGWindowAlpha as String: 1,
        ]
    }
}
