import CoreGraphics
import Foundation
import os.log
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
@MainActor
struct WindowVisibilityMetadataTests {
    @Test(arguments: [true, false, nil] as [Bool?])
    func `native visibility flag is independent of ordinary window geometry`(flag: Bool?) throws {
        let row = Self.windowDictionary(windowID: 900, flag: flag)
        let identity = try #require(SystemIdentityResolver.windowIdentity(900, in: [row]))
        let classic = try #require(LegacyScreenCaptureOperator.makeFilteringInfo(from: row, index: 0))

        #expect(identity.isOnScreen == (flag == true))
        #expect(classic.isOnScreen == identity.isOnScreen)
        #expect(classic.isOffScreen == !identity.isOnScreen)
        #expect(!classic.isMinimized)
        #expect(WindowFiltering.isRenderable(classic, mode: .list))
        #expect(WindowFiltering.isRenderable(classic, mode: .capture) == identity.isOnScreen)
    }

    @Test
    func `absent visibility does not outrank a genuinely on-screen classic candidate`() throws {
        let hidden = Self.windowDictionary(windowID: 900, flag: nil)
        let visible = Self.windowDictionary(windowID: 901, flag: true)

        #expect(LegacyScreenCaptureOperator.firstRenderableWindowIndex(in: [hidden, visible]) == 1)
        let hiddenIdentity = try #require(SystemIdentityResolver.windowIdentity(900, in: [hidden, visible]))
        #expect(!hiddenIdentity.isOnScreen)
        #expect(hiddenIdentity.windowID == 900)
    }

    @Test
    func `malformed visibility does not manufacture an on-screen window`() throws {
        for malformed: Any in ["true", NSNull(), [true]] {
            var row = Self.windowDictionary(windowID: 900, flag: nil)
            row[kCGWindowIsOnscreen as String] = malformed
            let classic = try #require(LegacyScreenCaptureOperator.makeFilteringInfo(from: row, index: 0))
            #expect(!classic.isOnScreen)
            #expect(classic.isOffScreen)
        }
    }

    @Test(arguments: [false, true])
    func `hidden nonminimized rows retain exact eligibility and inventory completeness`(axTimedOut: Bool) async throws {
        let process = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 7)
        let row = Self.windowDictionary(windowID: 900, flag: nil)
        let native = try #require(SystemIdentityResolver.windowIdentity(900, in: [row]))
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw FixtureError.unused },
            processStartIdentityProvider: { _ in process.processStartIdentity })
        let window = ServiceWindowInfo(
            windowID: 900,
            title: "Hidden fixture",
            bounds: native.bounds,
            isMinimized: false,
            isOnScreen: native.isOnScreen,
            mutationIdentity: WindowMutationIdentity(
                windowID: 900,
                ownerProcessIdentifier: process.processIdentifier,
                ownerProcessStartIdentity: process.processStartIdentity,
                capturedBounds: native.bounds,
                isMinimized: false))
        let context = WindowEnumerationContext(
            service: service,
            app: ServiceApplicationInfo(
                processIdentifier: process.processIdentifier,
                processStartIdentity: process.processStartIdentity,
                bundleIdentifier: "com.example.hidden-fixture",
                name: "Hidden fixture",
                isActive: false,
                isHidden: true),
            startTime: Date(),
            axTimeout: 0.05,
            hasScreenRecording: true,
            logger: Logger(subsystem: "boo.peekaboo.tests", category: "WindowVisibilityMetadata"),
            processIdentity: process,
            cgSnapshotProvider: { .init(windows: [window]) },
            applicationRunningProvider: { true },
            axEnumerator: { _, _ in
                DetachedAXWindowEnumerationResult(
                    descriptors: axTimedOut ? [] : [DetachedAXWindowDescriptor(
                        windowID: 900,
                        title: "Hidden fixture",
                        bounds: native.bounds,
                        isMinimized: false)],
                    focusedWindowID: nil,
                    timedOut: axTimedOut,
                    incomplete: axTimedOut,
                    reportedWindowCount: axTimedOut ? 0 : 1)
            })

        let output = try await context.run()
        let result = try #require(output.data.windows.first)
        let inventory: DesktopTargetPlanning.Inventory<ServiceWindowInfo> = .windowOutput(output)

        #expect(output.data.windows.map(\.windowID) == [900])
        #expect(!result.isOnScreen)
        #expect(!result.isMinimized)
        #expect(result.mutationIdentity == window.mutationIdentity)
        #expect(output.summary.status == (axTimedOut ? .partial : .success))
        #expect(inventory.isComplete == !axTimedOut)
        #expect(output.metadata.warnings.isEmpty == !axTimedOut)
        #expect(result.observationCapability == (axTimedOut
                ? .unknown(reason: .accessibilityEnumerationIncomplete)
                : .combinedEligible))
    }

    private static func windowDictionary(windowID: Int, flag: Bool?) -> [String: Any] {
        var row: [String: Any] = [
            kCGWindowNumber as String: windowID,
            kCGWindowOwnerPID as String: 42,
            kCGWindowBounds as String: CGRect(x: 100, y: 200, width: 800, height: 600).dictionaryRepresentation,
            kCGWindowLayer as String: 0,
            kCGWindowAlpha as String: 1.0,
        ]
        if let flag {
            row[kCGWindowIsOnscreen as String] = flag
        }
        return row
    }

    private enum FixtureError: Error {
        case unused
    }
}
