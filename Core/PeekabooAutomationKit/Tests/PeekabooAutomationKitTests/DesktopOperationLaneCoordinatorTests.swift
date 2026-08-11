import CoreGraphics
import Foundation
import PeekabooAutomationKitTestSupport
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
struct DesktopOperationLaneCoordinatorTests {
    @Test
    func `Sibling window writes can overlap while the same window remains exclusive`() async throws {
        let root = Self.temporaryDirectory(named: "siblings")
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let first = Self.window(windowID: 41)
        let second = Self.window(windowID: 42)
        let firstRelease = AsyncTestLatch()
        let firstStarted = AsyncTestLatch()
        let siblingStarted = AsyncTestLatch()
        let sameWindowStarted = AsyncTestLatch()

        let firstTask = Task {
            try await coordinator.run(scope: .window(first), access: .write) {
                await firstStarted.open()
                await firstRelease.wait()
            }
        }
        await firstStarted.wait()

        let siblingTask = Task {
            try await coordinator.run(scope: .window(second), access: .write) {
                await siblingStarted.open()
            }
        }
        let sameWindowTask = Task {
            try await coordinator.run(scope: .window(first), access: .write) {
                await sameWindowStarted.open()
            }
        }

        #expect(await siblingStarted.opensWithin(.seconds(1)))
        #expect(await !(sameWindowStarted.opensWithin(.milliseconds(100))))
        await firstRelease.open()
        try await firstTask.value
        try await siblingTask.value
        try await sameWindowTask.value
        #expect(await sameWindowStarted.isOpen)
    }

    @Test
    func `Window key ignores mutable receipt fields but includes process generation`() async throws {
        let root = Self.temporaryDirectory(named: "stable-window-key")
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let original = Self.window(windowID: 51, bounds: CGRect(x: 1, y: 2, width: 300, height: 200))
        let changedState = WindowMutationIdentity(
            windowID: original.windowID,
            ownerProcessIdentifier: original.ownerProcessIdentifier,
            ownerProcessStartIdentity: original.ownerProcessStartIdentity,
            capturedBounds: CGRect(x: 9, y: 8, width: 700, height: 600),
            isMinimized: true)
        let recycledGeneration = WindowMutationIdentity(
            windowID: original.windowID,
            ownerProcessIdentifier: original.ownerProcessIdentifier,
            ownerProcessStartIdentity: original.ownerProcessStartIdentity + 1,
            capturedBounds: original.capturedBounds,
            isMinimized: false)
        let release = AsyncTestLatch()
        let started = AsyncTestLatch()
        let sameStableIdentityStarted = AsyncTestLatch()
        let recycledStarted = AsyncTestLatch()

        let owner = Task {
            try await coordinator.run(scope: .window(original), access: .write) {
                await started.open()
                await release.wait()
            }
        }
        await started.wait()
        let sameStableIdentity = Task {
            try await coordinator.run(scope: .window(changedState), access: .write) {
                await sameStableIdentityStarted.open()
            }
        }
        let recycled = Task {
            try await coordinator.run(scope: .window(recycledGeneration), access: .write) {
                await recycledStarted.open()
            }
        }

        #expect(await !(sameStableIdentityStarted.opensWithin(.milliseconds(100))))
        #expect(await recycledStarted.opensWithin(.seconds(1)))
        await release.open()
        try await owner.value
        try await sameStableIdentity.value
        try await recycled.value
    }

    @Test
    func `Process write blocks its child windows but not a recycled process generation`() async throws {
        let root = Self.temporaryDirectory(named: "process")
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let process = ApplicationProcessIdentity(processIdentifier: 700, processStartIdentity: 100)
        let sameProcessWindow = Self.window(windowID: 61, process: process)
        let recycledWindow = Self.window(
            windowID: 61,
            process: ApplicationProcessIdentity(processIdentifier: 700, processStartIdentity: 101))
        let release = AsyncTestLatch()
        let processStarted = AsyncTestLatch()
        let sameProcessStarted = AsyncTestLatch()
        let recycledStarted = AsyncTestLatch()

        let owner = Task {
            try await coordinator.run(scope: .process(process), access: .write) {
                await processStarted.open()
                await release.wait()
            }
        }
        await processStarted.wait()
        let sameProcess = Task {
            try await coordinator.run(scope: .window(sameProcessWindow), access: .write) {
                await sameProcessStarted.open()
            }
        }
        let recycled = Task {
            try await coordinator.run(scope: .window(recycledWindow), access: .write) {
                await recycledStarted.open()
            }
        }

        #expect(await !(sameProcessStarted.opensWithin(.milliseconds(100))))
        #expect(await recycledStarted.opensWithin(.seconds(1)))
        await release.open()
        try await owner.value
        try await sameProcess.value
        try await recycled.value
    }

    @Test
    func `Global writer excludes every scoped operation`() async throws {
        let root = Self.temporaryDirectory(named: "global")
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let release = AsyncTestLatch()
        let globalStarted = AsyncTestLatch()
        let processStarted = AsyncTestLatch()
        let windowStarted = AsyncTestLatch()

        let owner = Task {
            try await coordinator.run(scope: .global, access: .write) {
                await globalStarted.open()
                await release.wait()
            }
        }
        await globalStarted.wait()
        let process = Task {
            try await coordinator.run(
                scope: .process(ApplicationProcessIdentity(processIdentifier: 800, processStartIdentity: 1)),
                access: .read)
            {
                await processStarted.open()
            }
        }
        let window = Task {
            try await coordinator.run(scope: .window(Self.window(windowID: 71)), access: .write) {
                await windowStarted.open()
            }
        }

        #expect(await !(processStarted.opensWithin(.milliseconds(100))))
        #expect(await !(windowStarted.opensWithin(.milliseconds(100))))
        await release.open()
        try await owner.value
        try await process.value
        try await window.value
    }

    @Test
    func `Queued cancellation releases partial ancestor claims and never dispatches`() async throws {
        let root = Self.temporaryDirectory(named: "queued-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstCoordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let secondCoordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let target = Self.window(windowID: 81)
        let release = AsyncTestLatch()
        let ownerStarted = AsyncTestLatch()
        let waiterDispatched = AsyncTestLatch()

        let owner = Task {
            try await firstCoordinator.run(scope: .window(target), access: .write) {
                await ownerStarted.open()
                await release.wait()
            }
        }
        await ownerStarted.wait()
        let waiter = Task {
            try await secondCoordinator.run(scope: .window(target), access: .write) {
                await waiterDispatched.open()
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        await release.open()

        try await owner.value
        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        #expect(await !(waiterDispatched.isOpen))
        try await secondCoordinator.run(scope: .global, access: .write) {}
    }

    @Test
    func `Active body that ignores cancellation retains its lease`() async throws {
        let root = Self.temporaryDirectory(named: "active-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let target = Self.window(windowID: 91)
        let activeStarted = AsyncTestLatch()
        let activeFinished = AsyncTestLatch()
        let contenderStarted = AsyncTestLatch()

        let active = Task {
            try await coordinator.run(scope: .window(target), access: .write) {
                await activeStarted.open()
                let noncooperative = Task.detached {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                await noncooperative.value
                await activeFinished.open()
            }
        }
        await activeStarted.wait()
        active.cancel()
        let contender = Task {
            try await coordinator.run(scope: .window(target), access: .write) {
                await contenderStarted.open()
            }
        }

        #expect(await !(contenderStarted.opensWithin(.milliseconds(100))))
        #expect(await activeFinished.opensWithin(.seconds(1)))
        _ = try? await active.value
        try await contender.value
        #expect(await contenderStarted.isOpen)
    }

    @Test
    func `Independent process flock excludes the coordinator`() async throws {
        let root = Self.temporaryDirectory(named: "subprocess")
        defer { try? FileManager.default.removeItem(at: root) }
        let child = Process()
        let ready = Pipe()
        let release = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = [
            "-c",
            """
            import fcntl, os, sys
            root = sys.argv[1]
            os.makedirs(root, mode=0o700, exist_ok=True)
            fd = os.open(os.path.join(root, "global.lock"), os.O_CREAT | os.O_RDWR, 0o600)
            fcntl.flock(fd, fcntl.LOCK_EX)
            sys.stdout.write("ready\\n")
            sys.stdout.flush()
            sys.stdin.buffer.read(1)
            """,
            root.path,
        ]
        child.standardOutput = ready
        child.standardInput = release
        try child.run()
        defer {
            if child.isRunning {
                child.terminate()
            }
        }
        let readyData = try #require(try ready.fileHandleForReading.read(upToCount: 6))
        #expect(String(data: readyData, encoding: .utf8) == "ready\n")

        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let dispatched = AsyncTestLatch()
        let contender = Task {
            try await coordinator.run(scope: .global, access: .read) {
                await dispatched.open()
            }
        }
        #expect(await !(dispatched.opensWithin(.milliseconds(100))))
        try release.fileHandleForWriting.write(contentsOf: Data([0]))
        child.waitUntilExit()

        try await contender.value
        #expect(await dispatched.isOpen)
    }

    @Test
    func `Unsafe root and hardlinked leaf fail before dispatch`() async throws {
        let parent = Self.temporaryDirectory(named: "unsafe-filesystem")
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let realRoot = parent.appendingPathComponent("real", isDirectory: true)
        let linkedRoot = parent.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)
        let symlinkDispatch = AsyncTestLatch()

        await #expect(throws: DesktopOperationLaneError.self) {
            try await DesktopOperationLaneCoordinator(coordinationRootURL: linkedRoot)
                .run(scope: .global, access: .write) {
                    await symlinkDispatch.open()
                }
        }
        #expect(await !(symlinkDispatch.isOpen))

        let hardlinkRoot = parent.appendingPathComponent("hardlink", isDirectory: true)
        try FileManager.default.createDirectory(at: hardlinkRoot, withIntermediateDirectories: false)
        let lock = hardlinkRoot.appendingPathComponent("global.lock", isDirectory: false)
        let alias = hardlinkRoot.appendingPathComponent("alias.lock", isDirectory: false)
        #expect(FileManager.default.createFile(atPath: lock.path, contents: Data()))
        try FileManager.default.linkItem(at: lock, to: alias)
        let hardlinkDispatch = AsyncTestLatch()
        await #expect(throws: DesktopOperationLaneError.self) {
            try await DesktopOperationLaneCoordinator(coordinationRootURL: hardlinkRoot)
                .run(scope: .global, access: .write) {
                    await hardlinkDispatch.open()
                }
        }
        #expect(await !(hardlinkDispatch.isOpen))
    }

    @Test
    func `Nested acquisition fails instead of deadlocking`() async throws {
        let root = Self.temporaryDirectory(named: "nested")
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)

        await #expect(throws: DesktopOperationLaneError.self) {
            try await coordinator.run(scope: .global, access: .write) {
                try await coordinator.run(scope: .window(Self.window(windowID: 101)), access: .write) {}
            }
        }
        try await coordinator.run(scope: .global, access: .write) {}
    }

    @Test
    func `Queued global writer closes the turnstile to later scoped readers`() async throws {
        let root = Self.temporaryDirectory(named: "writer-turnstile")
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let ownerStarted = AsyncTestLatch()
        let ownerRelease = AsyncTestLatch()
        let writerStarted = AsyncTestLatch()
        let writerRelease = AsyncTestLatch()
        let laterReaderStarted = AsyncTestLatch()

        let owner = Task {
            try await coordinator.run(scope: .global, access: .read) {
                await ownerStarted.open()
                await ownerRelease.wait()
            }
        }
        await ownerStarted.wait()
        let writer = Task {
            try await coordinator.run(scope: .global, access: .write) {
                await writerStarted.open()
                await writerRelease.wait()
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        let reader = Task {
            let process = ApplicationProcessIdentity(processIdentifier: 910, processStartIdentity: 1)
            try await coordinator.run(scope: .process(process), access: .read) {
                await laterReaderStarted.open()
            }
        }

        await ownerRelease.open()
        #expect(await writerStarted.opensWithin(.seconds(1)))
        #expect(await !(laterReaderStarted.opensWithin(.milliseconds(100))))
        await writerRelease.open()

        try await owner.value
        try await writer.value
        try await reader.value
        #expect(await laterReaderStarted.isOpen)
    }

    @Test
    func `Queued process writer closes its turnstile to later window readers`() async throws {
        let root = Self.temporaryDirectory(named: "process-writer-turnstile")
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let process = ApplicationProcessIdentity(processIdentifier: 920, processStartIdentity: 2)
        let firstWindow = Self.window(windowID: 111, process: process)
        let secondWindow = Self.window(windowID: 112, process: process)
        let ownerStarted = AsyncTestLatch()
        let ownerRelease = AsyncTestLatch()
        let writerStarted = AsyncTestLatch()
        let writerRelease = AsyncTestLatch()
        let laterReaderStarted = AsyncTestLatch()

        let owner = Task {
            try await coordinator.run(scope: .window(firstWindow), access: .read) {
                await ownerStarted.open()
                await ownerRelease.wait()
            }
        }
        await ownerStarted.wait()
        let writer = Task {
            try await coordinator.run(scope: .process(process), access: .write) {
                await writerStarted.open()
                await writerRelease.wait()
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        let reader = Task {
            try await coordinator.run(scope: .window(secondWindow), access: .read) {
                await laterReaderStarted.open()
            }
        }

        await ownerRelease.open()
        #expect(await writerStarted.opensWithin(.seconds(1)))
        #expect(await !(laterReaderStarted.opensWithin(.milliseconds(100))))
        await writerRelease.open()

        try await owner.value
        try await writer.value
        try await reader.value
        #expect(await laterReaderStarted.isOpen)
    }

    private static func window(
        windowID: Int,
        process: ApplicationProcessIdentity = .init(processIdentifier: 600, processStartIdentity: 10),
        bounds: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100)) -> WindowMutationIdentity
    {
        WindowMutationIdentity(
            windowID: windowID,
            ownerProcessIdentifier: process.processIdentifier,
            ownerProcessStartIdentity: process.processStartIdentity,
            capturedBounds: bounds,
            isMinimized: false)
    }

    private static func temporaryDirectory(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-operation-lanes-\(name)-\(UUID().uuidString)", isDirectory: true)
    }
}
