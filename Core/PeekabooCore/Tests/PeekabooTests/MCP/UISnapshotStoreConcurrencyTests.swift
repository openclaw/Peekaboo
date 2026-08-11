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
