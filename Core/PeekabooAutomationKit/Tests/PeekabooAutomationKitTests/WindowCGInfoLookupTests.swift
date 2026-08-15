import CoreGraphics
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct WindowCGInfoLookupTests {
    @Test
    func `exact lookup resolves an off-Space window from the full catalog without AX window identity`() throws {
        let bounds = CGRect(x: 10, y: 20, width: 800, height: 600)
        var queries: [(CGWindowListOption, CGWindowID)] = []
        var generations = [UInt64(9001), 9001]
        let lookup = WindowCGInfoLookup(
            windowListProvider: { options, relativeToWindow in
                queries.append((options, relativeToWindow))
                if options.contains(.optionIncludingWindow) {
                    return []
                }
                return [Self.windowDictionary(
                    windowID: 712,
                    ownerPID: 41,
                    bounds: bounds,
                    isOnScreen: false)]
            },
            processStartIdentityProvider: { _ in generations.removeFirst() },
            currentWindowIdentityProvider: { windowID in
                SystemWindowIdentity(
                    windowID: windowID,
                    ownerProcessIdentifier: 41,
                    title: "Current metadata",
                    bounds: bounds,
                    layer: 0,
                    alpha: 1,
                    isOnScreen: false,
                    sharingState: .readOnly)
            },
            isMainWindowProvider: { _ in false })

        let window = try #require(lookup.serviceWindowInfo(windowID: 712))

        #expect(window.windowID == 712)
        #expect(window.bounds == bounds)
        #expect(window.isOnScreen == false)
        #expect(window.mutationIdentity?.ownerProcessStartIdentity == 9001)
        #expect(queries.count == 2)
        #expect(queries[0].0.contains(.optionIncludingWindow))
        #expect(queries[0].1 == 712)
        #expect(queries[1].0.contains(.optionAll))
        #expect(queries[1].1 == kCGNullWindowID)
    }

    @Test
    func `exact lookup does not widen a missing ID to matching title owner or bounds`() {
        let bounds = CGRect(x: 10, y: 20, width: 800, height: 600)
        var currentIdentityRead = false
        let lookup = WindowCGInfoLookup(
            windowListProvider: { options, _ in
                if options.contains(.optionIncludingWindow) {
                    return []
                }
                return [Self.windowDictionary(
                    windowID: 713,
                    ownerPID: 41,
                    bounds: bounds,
                    isOnScreen: false)]
            },
            processStartIdentityProvider: { _ in 9001 },
            currentWindowIdentityProvider: { windowID in
                currentIdentityRead = true
                return SystemWindowIdentity(
                    windowID: windowID,
                    ownerProcessIdentifier: 41,
                    title: "Original metadata",
                    bounds: bounds,
                    layer: 0,
                    alpha: 1,
                    isOnScreen: false,
                    sharingState: .readOnly)
            },
            isMainWindowProvider: { _ in false })

        #expect(lookup.serviceWindowInfo(windowID: 712) == nil)
        #expect(!currentIdentityRead)
    }

    @Test
    func `exact lookup rejects full-catalog owner drift`() {
        let window = Self.fullCatalogWindowInfo(
            dictionaryOwner: 41,
            currentOwner: 52,
            dictionaryBounds: CGRect(x: 10, y: 20, width: 800, height: 600),
            currentBounds: CGRect(x: 10, y: 20, width: 800, height: 600),
            processGenerations: [9001, 9001])

        #expect(window == nil)
    }

    @Test
    func `exact lookup rejects full-catalog PID generation reuse`() {
        let bounds = CGRect(x: 10, y: 20, width: 800, height: 600)
        let window = Self.fullCatalogWindowInfo(
            dictionaryOwner: 41,
            currentOwner: 41,
            dictionaryBounds: bounds,
            currentBounds: bounds,
            processGenerations: [9001, 9002])

        #expect(window == nil)
    }

    @Test
    func `exact lookup rejects full-catalog bounds drift`() {
        let window = Self.fullCatalogWindowInfo(
            dictionaryOwner: 41,
            currentOwner: 41,
            dictionaryBounds: CGRect(x: 10, y: 20, width: 800, height: 600),
            currentBounds: CGRect(x: 30, y: 40, width: 640, height: 480),
            processGenerations: [9001, 9001])

        #expect(window == nil)
    }

    @Test
    func `exact lookup binds metadata and mutation identity to the dictionary owner`() throws {
        let window = try #require(Self.serviceWindowInfo(
            dictionaryOwner: 41,
            currentOwner: 41,
            processGenerations: [9001, 9001]))

        #expect(window.windowID == 712)
        #expect(window.title == "Original metadata")
        #expect(window.mutationIdentity == WindowMutationIdentity(
            windowID: 712,
            ownerProcessIdentifier: 41,
            ownerProcessStartIdentity: 9001,
            capturedBounds: CGRect(x: 10, y: 20, width: 800, height: 600),
            isMinimized: false))
    }

    @Test
    func `exact lookup rejects metadata after the window ID moves to another owner`() {
        let window = Self.serviceWindowInfo(
            dictionaryOwner: 41,
            currentOwner: 52,
            processGenerations: [9001])

        #expect(window == nil)
    }

    @Test
    func `exact lookup rejects metadata after the owner PID is reused`() {
        let window = Self.serviceWindowInfo(
            dictionaryOwner: 41,
            currentOwner: 41,
            processGenerations: [9001, 9002])

        #expect(window == nil)
    }

    @Test
    func `snapshot receipt rejects a replacement reusing the same window ID`() {
        let originalBounds = CGRect(x: 10, y: 20, width: 800, height: 600)
        let receipt = SystemIdentityResolver.windowMutationIdentity(
            snapshot: SystemIdentityResolver.WindowMutationSnapshot(
                windowID: 712,
                ownerProcessIdentifier: 41,
                ownerProcessStartIdentity: 9001,
                bounds: originalBounds,
                isMinimized: false),
            processStartIdentityProvider: { _ in 9001 },
            windowIdentityProvider: { windowID in
                SystemWindowIdentity(
                    windowID: windowID,
                    ownerProcessIdentifier: 41,
                    title: "Replacement",
                    bounds: CGRect(x: 30, y: 40, width: 640, height: 480),
                    layer: 0,
                    alpha: 1,
                    isOnScreen: true,
                    sharingState: .readOnly)
            })

        #expect(receipt == nil)
    }

    @Test
    func `AX minimized snapshot retains receipt when WindowServer omits entry`() {
        let bounds = CGRect(x: 10, y: 20, width: 800, height: 600)
        var generations = [UInt64(9001), 9001]
        let receipt = SystemIdentityResolver.axWindowMutationIdentity(
            snapshot: SystemIdentityResolver.WindowMutationSnapshot(
                windowID: 712,
                ownerProcessIdentifier: 41,
                ownerProcessStartIdentity: 9001,
                bounds: bounds,
                isMinimized: true),
            processStartIdentityProvider: { _ in generations.removeFirst() },
            windowIdentityProvider: { _ in nil })

        #expect(receipt?.capturedBounds == bounds)
        #expect(receipt?.isMinimized == true)
    }

    @Test
    func `AX absent receipt rejects visible state and process generation drift`() {
        let bounds = CGRect(x: 10, y: 20, width: 800, height: 600)
        let visible = SystemIdentityResolver.axWindowMutationIdentity(
            snapshot: SystemIdentityResolver.WindowMutationSnapshot(
                windowID: 712,
                ownerProcessIdentifier: 41,
                ownerProcessStartIdentity: 9001,
                bounds: bounds,
                isMinimized: false),
            processStartIdentityProvider: { _ in 9001 },
            windowIdentityProvider: { _ in nil })
        var generations = [UInt64(9001), 9002]
        let reused = SystemIdentityResolver.axWindowMutationIdentity(
            snapshot: SystemIdentityResolver.WindowMutationSnapshot(
                windowID: 712,
                ownerProcessIdentifier: 41,
                ownerProcessStartIdentity: 9001,
                bounds: bounds,
                isMinimized: true),
            processStartIdentityProvider: { _ in generations.removeFirst() },
            windowIdentityProvider: { _ in nil })

        #expect(visible == nil)
        #expect(reused == nil)
    }

    @Test
    func `mutation receipt rejects same process and window ID with changed bounds`() {
        let originalBounds = CGRect(x: 10, y: 20, width: 800, height: 600)
        let receipt = WindowMutationIdentity(
            windowID: 712,
            ownerProcessIdentifier: 41,
            ownerProcessStartIdentity: 9001,
            capturedBounds: originalBounds)

        let isValid = SystemIdentityResolver.validateWindowMutationIdentity(
            receipt,
            expectedBounds: originalBounds,
            processStartIdentityProvider: { _ in 9001 },
            windowIdentityProvider: { windowID in
                SystemWindowIdentity(
                    windowID: windowID,
                    ownerProcessIdentifier: 41,
                    title: "Replacement",
                    bounds: CGRect(x: 30, y: 40, width: 640, height: 480),
                    layer: 0,
                    alpha: 1,
                    isOnScreen: true,
                    sharingState: .readOnly)
            })

        #expect(!isValid)
    }

    @Test
    func `mutation receipt accepts unchanged captured window instance`() {
        let originalBounds = CGRect(x: 10, y: 20, width: 800, height: 600)
        let receipt = WindowMutationIdentity(
            windowID: 712,
            ownerProcessIdentifier: 41,
            ownerProcessStartIdentity: 9001,
            capturedBounds: originalBounds)

        let isValid = SystemIdentityResolver.validateWindowMutationIdentity(
            receipt,
            expectedBounds: originalBounds,
            processStartIdentityProvider: { _ in 9001 },
            windowIdentityProvider: { windowID in
                SystemWindowIdentity(
                    windowID: windowID,
                    ownerProcessIdentifier: 41,
                    title: "Original",
                    bounds: originalBounds,
                    layer: 0,
                    alpha: 1,
                    isOnScreen: true,
                    sharingState: .readOnly)
            })

        #expect(isValid)
    }

    @Test(arguments: [
        CGRect(x: 300, y: 400, width: 800, height: 600),
        CGRect(x: 10, y: 20, width: 500, height: 350),
        CGRect(x: 300, y: 400, width: 500, height: 350),
    ])
    func `geometry mutations repin their intended final bounds`(finalBounds: CGRect) {
        let originalBounds = CGRect(x: 10, y: 20, width: 800, height: 600)
        let receipt = WindowMutationIdentity(
            windowID: 712,
            ownerProcessIdentifier: 41,
            ownerProcessStartIdentity: 9001,
            capturedBounds: originalBounds)
        let finalReceipt = WindowMutationIdentity(
            windowID: 712,
            ownerProcessIdentifier: 41,
            ownerProcessStartIdentity: 9001,
            capturedBounds: finalBounds)

        let repinned = SystemIdentityResolver.repinWindowMutationIdentity(
            receipt,
            expectedBounds: finalBounds,
            tolerance: 1,
            providers: SystemIdentityResolver.WindowMutationIdentityProviders(
                processStartIdentity: { _ in 9001 },
                windowIdentity: { windowID in
                    SystemWindowIdentity(
                        windowID: windowID,
                        ownerProcessIdentifier: 41,
                        title: "Original after geometry mutation",
                        bounds: finalBounds,
                        layer: 0,
                        alpha: 1,
                        isOnScreen: true,
                        sharingState: .readOnly)
                },
                mutationIdentity: { _ in finalReceipt }))

        #expect(repinned?.capturedBounds == finalBounds)
    }

    private static func serviceWindowInfo(
        dictionaryOwner: pid_t,
        currentOwner: pid_t,
        processGenerations: [UInt64]) -> ServiceWindowInfo?
    {
        var remainingGenerations = processGenerations
        return WindowCGInfoLookup.serviceWindowInfo(
            windowID: 712,
            windowList: [[
                kCGWindowNumber as String: 712,
                kCGWindowOwnerPID as String: Int(dictionaryOwner),
                kCGWindowName as String: "Original metadata",
                kCGWindowBounds as String: [
                    "X": 10,
                    "Y": 20,
                    "Width": 800,
                    "Height": 600,
                ],
                kCGWindowLayer as String: 0,
                kCGWindowAlpha as String: 1.0,
                kCGWindowIsOnscreen as String: true,
            ]],
            isMainWindowProvider: { _ in true },
            processStartIdentityProvider: { _ in
                guard !remainingGenerations.isEmpty else { return nil }
                return remainingGenerations.removeFirst()
            },
            currentWindowIdentityProvider: { windowID in
                SystemWindowIdentity(
                    windowID: windowID,
                    ownerProcessIdentifier: currentOwner,
                    title: "Current metadata",
                    bounds: CGRect(x: 10, y: 20, width: 800, height: 600),
                    layer: 0,
                    alpha: 1,
                    isOnScreen: true,
                    sharingState: .readOnly)
            })
    }

    private static func fullCatalogWindowInfo(
        dictionaryOwner: pid_t,
        currentOwner: pid_t,
        dictionaryBounds: CGRect,
        currentBounds: CGRect,
        processGenerations: [UInt64]) -> ServiceWindowInfo?
    {
        var remainingGenerations = processGenerations
        let lookup = WindowCGInfoLookup(
            windowListProvider: { options, _ in
                if options.contains(.optionIncludingWindow) {
                    return []
                }
                return [Self.windowDictionary(
                    windowID: 712,
                    ownerPID: dictionaryOwner,
                    bounds: dictionaryBounds,
                    isOnScreen: false)]
            },
            processStartIdentityProvider: { _ in
                guard !remainingGenerations.isEmpty else { return nil }
                return remainingGenerations.removeFirst()
            },
            currentWindowIdentityProvider: { windowID in
                SystemWindowIdentity(
                    windowID: windowID,
                    ownerProcessIdentifier: currentOwner,
                    title: "Current metadata",
                    bounds: currentBounds,
                    layer: 0,
                    alpha: 1,
                    isOnScreen: false,
                    sharingState: .readOnly)
            },
            isMainWindowProvider: { _ in false })
        return lookup.serviceWindowInfo(windowID: 712)
    }

    private static func windowDictionary(
        windowID: Int,
        ownerPID: pid_t,
        bounds: CGRect,
        isOnScreen: Bool) -> [String: Any]
    {
        [
            kCGWindowNumber as String: windowID,
            kCGWindowOwnerPID as String: Int(ownerPID),
            kCGWindowName as String: "Original metadata",
            kCGWindowBounds as String: bounds.dictionaryRepresentation,
            kCGWindowLayer as String: 0,
            kCGWindowAlpha as String: 1.0,
            kCGWindowIsOnscreen as String: isOnScreen,
        ]
    }
}
