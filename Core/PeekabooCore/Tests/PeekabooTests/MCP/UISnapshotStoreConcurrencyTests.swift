import CoreGraphics
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooAgentRuntime

struct UISnapshotStoreConcurrencyTests {
    @Test
    func `atomic observation publishes exact focused element receipt`() async throws {
        let snapshot = UISnapshot()
        let bounds = CGRect(x: 10, y: 20, width: 400, height: 300)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 900,
            ownerProcessStartIdentity: 90,
            capturedBounds: bounds)
        let focused = FocusedElementIdentity(
            processIdentifier: 900,
            windowID: 42,
            role: "AXTextField",
            identifier: "editor",
            frame: CGRect(x: 40, y: 60, width: 200, height: 30))

        await snapshot.setScreenshot(
            path: "/tmp/screenshot.png",
            metadata: CaptureMetadata(
                size: bounds.size,
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 900,
                    processStartIdentity: 90,
                    bundleIdentifier: "com.example.editor",
                    name: "Editor"),
                windowInfo: ServiceWindowInfo(
                    windowID: 42,
                    title: "Document",
                    bounds: bounds,
                    mutationIdentity: identity)),
            context: WindowContext(
                applicationName: "Editor",
                applicationProcessId: 900,
                windowTitle: "Document",
                windowID: 42,
                windowBounds: bounds,
                windowMutationIdentity: identity,
                focusedElement: focused))

        #expect(snapshot.focusedElement == focused)
        #expect(try snapshot.targetReceipt().identity?.exactWindow?.focusedElement == focused)
    }

    @Test
    func `fresh detection supplies exact focus receipt when capture has no window`() async throws {
        let snapshot = UISnapshot()
        let bounds = CGRect(x: 10, y: 20, width: 400, height: 300)
        let context = Self.exactContext(bounds: bounds)

        await snapshot.setScreenshot(
            path: "/tmp/screenshot.png",
            metadata: Self.captureMetadata(window: nil, bounds: bounds),
            context: context)

        #expect(!snapshot.targetReceiptInvalidated)
        #expect(snapshot.applicationProcessIdentity == ApplicationProcessIdentity(
            processIdentifier: 900,
            processStartIdentity: 90))
        #expect(snapshot.windowMutationIdentity == context.windowMutationIdentity)
        #expect(snapshot.windowBounds == bounds)
        #expect(snapshot.focusedElement == context.focusedElement)
        #expect(try snapshot.targetReceipt().identity?.exactWindow?.focusedElement == context.focusedElement)
    }

    @Test
    func `capture and detection publication order preserves the same exact receipt`() async throws {
        let bounds = CGRect(x: 10, y: 20, width: 400, height: 300)
        let context = Self.exactContext(bounds: bounds)
        let metadata = Self.captureMetadata(window: nil, bounds: bounds)

        let captureFirst = UISnapshot()
        await captureFirst.setScreenshot(path: "/tmp/capture-first.png", metadata: metadata)
        await captureFirst.setTargetMetadata(from: context)

        let detectionFirst = UISnapshot()
        await detectionFirst.setTargetMetadata(from: context)
        await detectionFirst.setScreenshot(
            path: "/tmp/detection-first.png",
            metadata: metadata,
            context: context)

        for snapshot in [captureFirst, detectionFirst] {
            #expect(!snapshot.targetReceiptInvalidated)
            #expect(try snapshot.targetReceipt().identity?.exactWindow?.focusedElement == context.focusedElement)
        }
    }

    @Test
    func `atomic observation permanently invalidates actual target disagreements`() async throws {
        let bounds = CGRect(x: 10, y: 20, width: 400, height: 300)
        let captureWindow = ServiceWindowInfo(
            windowID: 42,
            title: "Document",
            bounds: bounds,
            mutationIdentity: WindowMutationIdentity(
                windowID: 42,
                ownerProcessIdentifier: 900,
                ownerProcessStartIdentity: 90,
                capturedBounds: bounds))
        let wrongBounds = CGRect(x: 20, y: 20, width: 400, height: 300)
        let contexts = [
            Self.exactContext(processIdentifier: 901, bounds: bounds),
            Self.exactContext(processGeneration: 91, bounds: bounds),
            Self.exactContext(windowID: 43, bounds: bounds),
            Self.exactContext(bounds: wrongBounds),
            Self.exactContext(focusedWindowID: 43, bounds: bounds),
        ]

        for context in contexts {
            let snapshot = UISnapshot()
            await snapshot.setScreenshot(
                path: "/tmp/conflict.png",
                metadata: Self.captureMetadata(window: captureWindow, bounds: bounds),
                context: context)

            #expect(snapshot.targetReceiptInvalidated)
            #expect(snapshot.windowMutationIdentity == nil)
            #expect(snapshot.focusedElement == nil)
            #expect(try snapshot.targetReceipt().targetEvidence == .invalidated)
        }
    }

    @Test
    func `fresh focus replaces mutable focus without invalidating stable target`() async {
        let snapshot = UISnapshot()
        let bounds = CGRect(x: 10, y: 20, width: 400, height: 300)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 900,
            ownerProcessStartIdentity: 90,
            capturedBounds: bounds)
        func context(identifier: String?) -> WindowContext {
            WindowContext(
                applicationName: "Editor",
                applicationProcessId: 900,
                windowTitle: "Document",
                windowID: 42,
                windowBounds: bounds,
                windowMutationIdentity: identity,
                focusedElement: identifier.map {
                    FocusedElementIdentity(
                        processIdentifier: 900,
                        windowID: 42,
                        role: "AXTextField",
                        identifier: $0,
                        frame: CGRect(x: $0 == "first" ? 40 : 250, y: 60, width: 120, height: 30))
                })
        }

        await snapshot.setTargetMetadata(from: context(identifier: "first"))
        await snapshot.setTargetMetadata(from: context(identifier: "second"))
        #expect(!snapshot.targetReceiptInvalidated)
        #expect(snapshot.focusedElement?.identifier == "second")

        await snapshot.setTargetMetadata(from: context(identifier: nil))
        #expect(!snapshot.targetReceiptInvalidated)
        #expect(snapshot.focusedElement == nil)
    }

    @Test
    func `malformed focused receipt invalidates snapshot target`() async throws {
        let snapshot = UISnapshot()
        let bounds = CGRect(x: 10, y: 20, width: 400, height: 300)
        await snapshot.setTargetMetadata(from: WindowContext(
            applicationName: "Editor",
            applicationProcessId: 900,
            windowTitle: "Document",
            windowID: 42,
            windowBounds: bounds,
            windowMutationIdentity: WindowMutationIdentity(
                windowID: 42,
                ownerProcessIdentifier: 900,
                ownerProcessStartIdentity: 90,
                capturedBounds: bounds),
            focusedElement: FocusedElementIdentity(
                processIdentifier: 900,
                windowID: 99,
                role: "AXTextField",
                frame: CGRect(x: 40, y: 60, width: 120, height: 30))))

        #expect(snapshot.targetReceiptInvalidated)
        #expect(try snapshot.targetReceipt().targetEvidence == .invalidated)
    }

    @Test
    func `same process detection metadata preserves capture generation receipt`() async {
        let snapshot = UISnapshot()
        await snapshot.setScreenshot(
            path: "/tmp/screenshot.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 901,
                    processStartIdentity: 91,
                    bundleIdentifier: "com.example.editor",
                    name: "Editor")))

        await snapshot.setTargetMetadata(from: WindowContext(
            applicationName: "Editor",
            applicationProcessId: 901,
            windowTitle: "Document"))

        #expect(snapshot.applicationProcessIdentity == ApplicationProcessIdentity(
            processIdentifier: 901,
            processStartIdentity: 91))
    }

    @Test
    func `receiptless window metadata does not mint exact-window authority`() async throws {
        let snapshot = UISnapshot()
        let bounds = CGRect(x: 10, y: 20, width: 200, height: 100)
        await snapshot.setScreenshot(
            path: "/tmp/screenshot.png",
            metadata: CaptureMetadata(
                size: bounds.size,
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 901,
                    processStartIdentity: 91,
                    bundleIdentifier: "com.example.editor",
                    name: "Editor")))

        await snapshot.setTargetMetadata(from: WindowContext(
            applicationName: "Editor",
            applicationProcessId: 901,
            windowTitle: "Document",
            windowID: 42,
            windowBounds: bounds))

        let identity = try snapshot.targetReceipt().requireIdentity()
        #expect(identity.processIdentity == ApplicationProcessIdentity(
            processIdentifier: 901,
            processStartIdentity: 91))
        #expect(identity.exactWindow == nil)
        #expect(!snapshot.targetReceiptInvalidated)
    }

    @Test
    func `screenshot rejects conflicting application and window receipts`() async {
        let conflictingIdentities = [
            WindowMutationIdentity(
                windowID: 42,
                ownerProcessIdentifier: 905,
                ownerProcessStartIdentity: 96),
            WindowMutationIdentity(
                windowID: 42,
                ownerProcessIdentifier: 906,
                ownerProcessStartIdentity: 95),
        ]

        for identity in conflictingIdentities {
            let snapshot = UISnapshot()
            await snapshot.setScreenshot(
                path: "/tmp/screenshot.png",
                metadata: CaptureMetadata(
                    size: CGSize(width: 200, height: 100),
                    mode: .window,
                    applicationInfo: ServiceApplicationInfo(
                        processIdentifier: 905,
                        processStartIdentity: 95,
                        bundleIdentifier: "com.example.editor",
                        name: "Editor"),
                    windowInfo: ServiceWindowInfo(
                        windowID: 42,
                        title: "Document",
                        bounds: CGRect(x: 10, y: 20, width: 200, height: 100),
                        mutationIdentity: identity)))

            #expect(snapshot.applicationProcessIdentity == nil)
            #expect(snapshot.windowMutationIdentity == nil)
        }
    }

    @Test
    func `window-only screenshot receipt cannot be replaced by another process`() async {
        let snapshot = UISnapshot()
        await snapshot.setScreenshot(
            path: "/tmp/first.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                windowInfo: ServiceWindowInfo(
                    windowID: 42,
                    title: "First",
                    bounds: CGRect(x: 10, y: 20, width: 200, height: 100),
                    mutationIdentity: WindowMutationIdentity(
                        windowID: 42,
                        ownerProcessIdentifier: 907,
                        ownerProcessStartIdentity: 97))))
        #expect(snapshot.applicationProcessIdentity == ApplicationProcessIdentity(
            processIdentifier: 907,
            processStartIdentity: 97))

        await snapshot.setScreenshot(
            path: "/tmp/second.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                windowInfo: ServiceWindowInfo(
                    windowID: 43,
                    title: "Second",
                    bounds: CGRect(x: 10, y: 20, width: 200, height: 100),
                    mutationIdentity: WindowMutationIdentity(
                        windowID: 43,
                        ownerProcessIdentifier: 908,
                        ownerProcessStartIdentity: 98))))

        #expect(snapshot.windowMutationIdentity == nil)
    }

    @Test
    func `receiptless screenshot update cannot hide later process replacement`() async {
        let snapshot = UISnapshot()
        await snapshot.setScreenshot(
            path: "/tmp/first.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 909,
                    processStartIdentity: 99,
                    bundleIdentifier: "com.example.first",
                    name: "First")))

        await snapshot.setScreenshot(
            path: "/tmp/receiptless.png",
            metadata: CaptureMetadata(size: CGSize(width: 200, height: 100), mode: .window))
        #expect(snapshot.applicationProcessIdentity == nil)

        await snapshot.setScreenshot(
            path: "/tmp/second.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 910,
                    processStartIdentity: 100,
                    bundleIdentifier: "com.example.second",
                    name: "Second")))

        #expect(snapshot.applicationProcessIdentity == nil)
        #expect(snapshot.windowMutationIdentity == nil)
    }

    @Test
    func `exact window screenshot receipt cannot be replaced or removed`() async {
        for replacementWindowID in [Int?(43), nil] {
            let snapshot = UISnapshot()
            let application = ServiceApplicationInfo(
                processIdentifier: 911,
                processStartIdentity: 101,
                bundleIdentifier: "com.example.editor",
                name: "Editor")
            await snapshot.setScreenshot(
                path: "/tmp/first.png",
                metadata: CaptureMetadata(
                    size: CGSize(width: 200, height: 100),
                    mode: .window,
                    applicationInfo: application,
                    windowInfo: ServiceWindowInfo(
                        windowID: 42,
                        title: "First",
                        bounds: CGRect(x: 10, y: 20, width: 200, height: 100),
                        mutationIdentity: WindowMutationIdentity(
                            windowID: 42,
                            ownerProcessIdentifier: 911,
                            ownerProcessStartIdentity: 101))))

            let replacementWindow = replacementWindowID.map { windowID in
                ServiceWindowInfo(
                    windowID: windowID,
                    title: "Replacement",
                    bounds: CGRect(x: 10, y: 20, width: 200, height: 100),
                    mutationIdentity: WindowMutationIdentity(
                        windowID: windowID,
                        ownerProcessIdentifier: 911,
                        ownerProcessStartIdentity: 101))
            }
            await snapshot.setScreenshot(
                path: "/tmp/replacement.png",
                metadata: CaptureMetadata(
                    size: CGSize(width: 200, height: 100),
                    mode: .window,
                    applicationInfo: application,
                    windowInfo: replacementWindow))

            #expect(snapshot.applicationProcessIdentity == nil)
            #expect(snapshot.windowMutationIdentity == nil)
        }
    }

    @Test
    func `conflicting detection generation permanently invalidates snapshot receipt`() async throws {
        let snapshot = UISnapshot()
        await snapshot.setScreenshot(
            path: "/tmp/screenshot.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 902,
                    processStartIdentity: 92,
                    bundleIdentifier: "com.example.editor",
                    name: "Editor")))
        let conflictingContext = WindowContext(
            applicationName: "Editor",
            applicationProcessId: 902,
            windowTitle: "Document",
            windowID: 42,
            windowBounds: CGRect(x: 10, y: 20, width: 200, height: 100),
            windowMutationIdentity: WindowMutationIdentity(
                windowID: 42,
                ownerProcessIdentifier: 902,
                ownerProcessStartIdentity: 93))

        await snapshot.setTargetMetadata(from: conflictingContext)
        #expect(snapshot.applicationProcessIdentity == nil)
        #expect(snapshot.windowMutationIdentity == nil)
        #expect(snapshot.targetReceiptInvalidated)
        #expect(try snapshot.targetReceipt().targetEvidence == .invalidated)

        await snapshot.setTargetMetadata(from: conflictingContext)
        #expect(snapshot.applicationProcessIdentity == nil)
        #expect(snapshot.windowMutationIdentity == nil)

        await snapshot.setScreenshot(
            path: "/tmp/replacement.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 902,
                    processStartIdentity: 92,
                    bundleIdentifier: "com.example.editor",
                    name: "Editor")))
        #expect(snapshot.applicationProcessIdentity == nil)
        #expect(snapshot.windowMutationIdentity == nil)
        #expect(try snapshot.targetReceipt().targetEvidence == .invalidated)
    }

    @Test
    func `conflicting detection process invalidates captured receipt`() async {
        let snapshot = UISnapshot()
        await snapshot.setScreenshot(
            path: "/tmp/screenshot.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 903,
                    processStartIdentity: 93,
                    bundleIdentifier: "com.example.editor",
                    name: "Editor")))

        await snapshot.setTargetMetadata(from: WindowContext(
            applicationName: "Other",
            applicationProcessId: 904,
            windowTitle: "Other Document",
            windowID: 43,
            windowBounds: CGRect(x: 10, y: 20, width: 200, height: 100),
            windowMutationIdentity: WindowMutationIdentity(
                windowID: 43,
                ownerProcessIdentifier: 904,
                ownerProcessStartIdentity: 94)))

        #expect(snapshot.applicationProcessIdentity == nil)
        #expect(snapshot.windowMutationIdentity == nil)
    }

    @Test
    func `detection metadata cannot rebind a window-only capture receipt`() async {
        let conflictingContexts = [
            WindowContext(
                applicationName: "Other Process",
                applicationProcessId: 913,
                windowTitle: "Other",
                windowID: 43,
                windowMutationIdentity: WindowMutationIdentity(
                    windowID: 43,
                    ownerProcessIdentifier: 913,
                    ownerProcessStartIdentity: 103)),
            WindowContext(
                applicationName: "Other Window",
                applicationProcessId: 912,
                windowTitle: "Other",
                windowID: 43,
                windowMutationIdentity: WindowMutationIdentity(
                    windowID: 43,
                    ownerProcessIdentifier: 912,
                    ownerProcessStartIdentity: 102)),
        ]

        for context in conflictingContexts {
            let snapshot = UISnapshot()
            await snapshot.setScreenshot(
                path: "/tmp/capture.png",
                metadata: CaptureMetadata(
                    size: CGSize(width: 200, height: 100),
                    mode: .window,
                    windowInfo: ServiceWindowInfo(
                        windowID: 42,
                        title: "Captured",
                        bounds: CGRect(x: 10, y: 20, width: 200, height: 100),
                        mutationIdentity: WindowMutationIdentity(
                            windowID: 42,
                            ownerProcessIdentifier: 912,
                            ownerProcessStartIdentity: 102))))

            await snapshot.setTargetMetadata(from: context)

            #expect(snapshot.applicationProcessIdentity == nil)
            #expect(snapshot.windowMutationIdentity == nil)
        }
    }

    @Test
    func `receiptless matching detection preserves window-only capture receipt`() async {
        let snapshot = UISnapshot()
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 914,
            ownerProcessStartIdentity: 104)
        await snapshot.setScreenshot(
            path: "/tmp/capture.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                windowInfo: ServiceWindowInfo(
                    windowID: 42,
                    title: "Captured",
                    bounds: CGRect(x: 10, y: 20, width: 200, height: 100),
                    mutationIdentity: identity)))

        await snapshot.setTargetMetadata(from: WindowContext(
            applicationName: "Editor",
            applicationProcessId: 914,
            windowTitle: "Captured",
            windowID: 42))

        #expect(snapshot.applicationProcessIdentity == ApplicationProcessIdentity(
            processIdentifier: 914,
            processStartIdentity: 104))
        #expect(snapshot.windowMutationIdentity == identity)
    }

    @Test
    func `target cache supports concurrent production reads and writes`() async {
        let contexts = [
            WindowContext(
                applicationName: "First application name long enough to use heap storage",
                applicationProcessId: 101,
                windowTitle: "First window title long enough to use heap storage"),
            WindowContext(
                applicationName: "Second application name long enough to use heap storage",
                applicationProcessId: 202,
                windowTitle: "Second window title long enough to use heap storage"),
        ]
        let allowedNames = Set(contexts.compactMap(\.applicationName))
        let allowedTitles = Set(contexts.compactMap(\.windowTitle))
        let allowedProcessIdentifiers = Set(contexts.compactMap(\.applicationProcessId))
        let snapshot = UISnapshot()
        await snapshot.setTargetMetadata(from: contexts[0])

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<2000 {
                    await snapshot.setTargetMetadata(from: contexts[index % contexts.count])
                }
            }

            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<5000 {
                        #expect(snapshot.applicationName.map(allowedNames.contains) == true)
                        #expect(snapshot.windowTitle.map(allowedTitles.contains) == true)
                        #expect(snapshot.applicationProcessId.map(allowedProcessIdentifiers.contains) == true)
                    }
                }
            }
        }
    }

    private static func captureMetadata(
        window: ServiceWindowInfo?,
        bounds: CGRect) -> CaptureMetadata
    {
        CaptureMetadata(
            size: bounds.size,
            mode: .window,
            applicationInfo: ServiceApplicationInfo(
                processIdentifier: 900,
                processStartIdentity: 90,
                bundleIdentifier: "com.example.editor",
                name: "Editor"),
            windowInfo: window)
    }

    private static func exactContext(
        processIdentifier: pid_t = 900,
        processGeneration: UInt64 = 90,
        windowID: Int = 42,
        focusedWindowID: Int? = nil,
        bounds: CGRect) -> WindowContext
    {
        let identity = WindowMutationIdentity(
            windowID: windowID,
            ownerProcessIdentifier: processIdentifier,
            ownerProcessStartIdentity: processGeneration,
            capturedBounds: bounds)
        return WindowContext(
            applicationName: "Editor",
            applicationProcessId: processIdentifier,
            windowTitle: "Document",
            windowID: windowID,
            windowBounds: bounds,
            windowMutationIdentity: identity,
            focusedElement: FocusedElementIdentity(
                processIdentifier: processIdentifier,
                windowID: focusedWindowID ?? windowID,
                role: "AXTextField",
                identifier: "editor",
                frame: CGRect(x: bounds.minX + 30, y: bounds.minY + 40, width: 200, height: 30)))
    }
}
