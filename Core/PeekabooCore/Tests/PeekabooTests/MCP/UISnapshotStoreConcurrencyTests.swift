import CoreGraphics
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooAgentRuntime

struct UISnapshotStoreConcurrencyTests {
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
    func `conflicting detection generation permanently invalidates snapshot receipt`() async {
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
}
