import Darwin
import DescriptorForkTestSupport
import Foundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
struct ScreenCaptureKitOwnerLeaseTests {
    @Test
    func `Default lock has a stable name inside the per-user temporary directory`() {
        let byteCount = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard byteCount > 0 else {
            Issue.record("The canonical per-user temporary directory is unavailable")
            return
        }
        var buffer = [CChar](repeating: 0, count: byteCount)
        #expect(confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, byteCount) > 0)
        let pathBytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        guard let expectedPath = String(bytes: pathBytes, encoding: .utf8) else {
            Issue.record("The canonical per-user temporary directory is not valid UTF-8")
            return
        }
        let expectedDirectory = URL(
            fileURLWithPath: expectedPath,
            isDirectory: true).standardizedFileURL

        #expect(ScreenCaptureKitOwnerLease.defaultLockURL.deletingLastPathComponent() == expectedDirectory)
        #expect(ScreenCaptureKitOwnerLease.defaultLockURL.lastPathComponent == "boo.peekaboo.sckit-owner.lock")
    }

    @Test
    func `Process capability marker is build bound and held for process lifetime`() throws {
        let fixture = try LeaseFixture(name: "capability-marker")
        defer { fixture.removeLockPath() }
        let ownerIdentity = ScreenCaptureKitOwnerLease.OwnerIdentity(
            processIdentifier: 42420,
            processStartIdentity: 9001,
            buildIdentity: "synthetic-marker-build",
            codeSignatureHash: "synthetic-marker-cdhash")
        let signatureIdentity = ScreenCaptureKitOwnerLease.CodeSignatureIdentity(
            signingIdentifier: "test.peekaboo.marker",
            teamIdentifier: "TESTTEAM",
            codeSignatureHash: ownerIdentity.codeSignatureHash)

        try ScreenCaptureKitProcessCapabilityRegistry.register(
            ownerIdentity: ownerIdentity,
            directory: fixture.directoryURL,
            signatureIdentity: signatureIdentity)

        let markerURL = ScreenCaptureKitOwnerLease.processCapabilityMarkerURL(
            processIdentifier: ownerIdentity.processIdentifier,
            processStartIdentity: ownerIdentity.processStartIdentity,
            directory: fixture.directoryURL)
        let receiptData = try Data(contentsOf: markerURL)
        let receipt = try JSONDecoder().decode(
            ScreenCaptureKitOwnerLease.ProcessCapabilityReceipt.self,
            from: receiptData)
        #expect(receipt.processIdentifier == ownerIdentity.processIdentifier)
        #expect(receipt.processStartIdentity == ownerIdentity.processStartIdentity)
        #expect(receipt.buildIdentity == ownerIdentity.buildIdentity)
        #expect(receipt.codeSignatureHash == ownerIdentity.codeSignatureHash)
        #expect(receipt.signingIdentifier == signatureIdentity.signingIdentifier)
        #expect(receipt.teamIdentifier == signatureIdentity.teamIdentifier)

        var fileInfo = stat()
        #expect(lstat(markerURL.path, &fileInfo) == 0)
        #expect(fileInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
        #expect(fileInfo.st_uid == geteuid())
        #expect(fileInfo.st_nlink == 1)
        #expect(fileInfo.st_mode & mode_t(S_IRWXU | S_IRWXG | S_IRWXO) == mode_t(S_IRUSR | S_IWUSR))
        let heldDescriptor = try #require(self.descriptor(for: fileInfo))
        self.expectLiveCloseOnExecDescriptor(heldDescriptor, matching: fileInfo)

        try ScreenCaptureKitProcessCapabilityRegistry.register(
            ownerIdentity: .init(
                processIdentifier: ownerIdentity.processIdentifier,
                processStartIdentity: ownerIdentity.processStartIdentity,
                buildIdentity: "replacement-build",
                codeSignatureHash: "replacement-cdhash"),
            directory: fixture.directoryURL,
            signatureIdentity: .init(
                signingIdentifier: "test.peekaboo.replacement",
                teamIdentifier: "REPLACEMENT",
                codeSignatureHash: "replacement-cdhash"))
        #expect(try Data(contentsOf: markerURL) == receiptData)

        var reentryInfo = stat()
        #expect(lstat(markerURL.path, &reentryInfo) == 0)
        #expect(reentryInfo.st_dev == fileInfo.st_dev)
        #expect(reentryInfo.st_ino == fileInfo.st_ino)
        #if compiler(>=6.4)
        #expect(peekaboo_probe_descriptor_after_fork(heldDescriptor) == DescriptorForkProbeClosed)
        #endif
        self.expectLiveCloseOnExecDescriptor(heldDescriptor, matching: fileInfo)
        #expect(try Data(contentsOf: markerURL) == receiptData)

        let contender = open(markerURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        #expect(contender >= 0)
        if contender >= 0 {
            defer { close(contender) }
            #expect(flock(contender, LOCK_EX | LOCK_NB) == -1)
            #expect(errno == EWOULDBLOCK || errno == EAGAIN)
        }
    }

    @Test
    func `Fork probe inherits a close-on-exec-only descriptor`() throws {
        let fixture = try LeaseFixture(name: "fork-cloexec-control")
        defer { fixture.removeLockPath() }
        let descriptor = open(fixture.lockURL.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        var fileInfo = stat()
        try #require(fstat(descriptor, &fileInfo) == 0)
        self.expectLiveCloseOnExecDescriptor(descriptor, matching: fileInfo)

        #expect(peekaboo_probe_descriptor_after_fork(descriptor) == DescriptorForkProbeInherited)

        self.expectLiveCloseOnExecDescriptor(descriptor, matching: fileInfo)
    }

    @Test(arguments: [Int32(-1), Int32.max])
    func `Fork probe rejects invalid input as an error`(descriptor: Int32) {
        #expect(peekaboo_probe_descriptor_after_fork(descriptor) == DescriptorForkProbeInputError)
    }

    #if compiler(>=6.4)
    @Test(arguments: [false, true])
    func `Atomic owner open flags close descriptors across fork`(useOpenAt: Bool) throws {
        let fixture = try LeaseFixture(name: "fork-atomic-open")
        defer { fixture.removeLockPath() }
        let directory = open(fixture.directoryURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try #require(directory >= 0)
        defer { close(directory) }
        let flags = O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | ScreenCaptureKitOwnerLease.closeOnForkOpenFlag | O_NOFOLLOW
        let descriptor = useOpenAt
            ? openat(directory, fixture.lockURL.lastPathComponent, flags, S_IRUSR | S_IWUSR)
            : open(fixture.lockURL.path, flags, S_IRUSR | S_IWUSR)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        var fileInfo = stat()
        try #require(fstat(descriptor, &fileInfo) == 0)
        self.expectLiveCloseOnExecDescriptor(descriptor, matching: fileInfo)

        #expect(ScreenCaptureKitOwnerLease.closeOnForkOpenFlag == O_CLOFORK)
        #expect(peekaboo_probe_descriptor_after_fork(descriptor) == DescriptorForkProbeClosed)

        self.expectLiveCloseOnExecDescriptor(descriptor, matching: fileInfo)
    }
    #endif

    @Test
    func `Pre-lease process blocks claim before owner file creation`() throws {
        let fixture = try LeaseFixture(name: "pre-lease-process")
        defer { fixture.removeLockPath() }
        let conflict = ScreenCaptureKitOwnerLease.UncoordinatedProcess(
            processIdentifier: 4242,
            processStartIdentity: 9001,
            executablePath: "/Applications/Peekaboo.app/Contents/MacOS/Peekaboo")
        let lease = ScreenCaptureKitOwnerLease(
            lockURL: fixture.lockURL,
            ownerIdentity: .init(
                processIdentifier: getpid(),
                processStartIdentity: fixture.processStartIdentity,
                buildIdentity: "paired-upgrade-build"),
            uncoordinatedProcesses: { [conflict] })

        #expect(throws: ScreenCaptureKitOwnerLease.LeaseError.uncoordinatedProcesses([conflict])) {
            try lease.claim()
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.lockURL.path))
    }

    @Test
    func `Pre-lease Bridge host blocks claim before owner file creation`() throws {
        let fixture = try LeaseFixture(name: "pre-lease-host")
        defer { fixture.removeLockPath() }
        let conflict = ScreenCaptureKitOwnerLease.UncoordinatedHost(
            socketPath: "/tmp/old-bridge.sock",
            processIdentifier: 4242,
            processStartIdentity: 9001)
        let lease = ScreenCaptureKitOwnerLease(
            lockURL: fixture.lockURL,
            ownerIdentity: .init(
                processIdentifier: getpid(),
                processStartIdentity: fixture.processStartIdentity,
                buildIdentity: "paired-upgrade-build"),
            uncoordinatedHosts: { [conflict] })

        #expect(throws: ScreenCaptureKitOwnerLease.LeaseError.uncoordinatedHosts([conflict])) {
            try lease.claim()
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.lockURL.path))
    }

    @Test
    func `Stale marker and unrelated signed executable cannot satisfy process awareness`() throws {
        let fixture = try LeaseFixture(name: "stale-capability")
        defer { fixture.removeLockPath() }
        let staleGeneration = fixture.processStartIdentity &+ 1
        let markerURL = ScreenCaptureKitOwnerLease.processCapabilityMarkerURL(
            processIdentifier: getpid(),
            processStartIdentity: staleGeneration,
            directory: fixture.lockURL.deletingLastPathComponent())
        let staleReceipt = ScreenCaptureKitOwnerLease.ProcessCapabilityReceipt(
            processIdentifier: getpid(),
            processStartIdentity: staleGeneration,
            buildIdentity: "sha256:stale",
            codeSignatureHash: nil,
            signingIdentifier: "boo.peekaboo.peekaboo",
            teamIdentifier: nil)
        try JSONEncoder().encode(staleReceipt).write(to: markerURL)
        #expect(chmod(markerURL.path, S_IRUSR | S_IWUSR) == 0)

        #expect(!ScreenCaptureKitOwnerLease.hasValidProcessCapability(
            processIdentifier: getpid(),
            processStartIdentity: staleGeneration,
            executablePath: CommandLine.arguments[0],
            signature: nil,
            directory: fixture.lockURL.deletingLastPathComponent()))
    }

    @Test
    func `Potential host classification includes only exact entry points`() throws {
        let signedHosts: [(path: String, signingIdentifier: String)] = [
            ("/tmp/renamed-cli", "peekaboo"),
            ("/tmp/renamed-debug-cli", "boo.peekaboo"),
            ("/tmp/renamed-cli", "boo.peekaboo.peekaboo"),
            ("/Applications/Peekaboo.app/Contents/MacOS/Peekaboo", "boo.peekaboo.mac"),
            ("/Applications/Peekaboo.app/Contents/MacOS/Peekaboo", "boo.peekaboo.mac.debug"),
            ("/Applications/Claude.app/Contents/MacOS/Claude", "com.anthropic.claudefordesktop"),
            ("/Applications/Clawdis.app/Contents/MacOS/Clawdis", "com.clawdis.mac"),
            ("/Applications/Clawdbot.app/Contents/MacOS/Clawdbot", "com.clawdbot.mac.debug"),
            ("/Applications/Moltbot.app/Contents/MacOS/Moltbot", "bot.molt.mac"),
            ("/Applications/OpenClaw.app/Contents/MacOS/OpenClaw", "ai.openclaw.mac.debug"),
        ]
        for host in signedHosts {
            #expect(ScreenCaptureKitOwnerLease.isPotentialPeekabooProcess(
                executablePath: host.path,
                signingIdentifier: host.signingIdentifier))
        }
        #expect(ScreenCaptureKitOwnerLease.isPotentialPeekabooProcess(
            executablePath: "/tmp/peekaboo",
            signingIdentifier: nil))

        let nonHosts: [(path: String, signingIdentifier: String?)] = [
            ("/tmp/peekaboo", "com.apple.sleep"),
            (
                "/Users/test/Library/Application Support/Claude/claude-code/2.1.222/" +
                    "claude.app/Contents/MacOS/claude",
                "com.anthropic.claude-code"),
            (
                "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper",
                "com.anthropic.claudefordesktop.helper"),
            (
                "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/" +
                    "Claude Helper (Renderer)",
                "com.anthropic.claudefordesktop.helper"),
            (
                "/Applications/Claude.app/Contents/Frameworks/Electron Framework.framework/Helpers/" +
                    "chrome_crashpad_handler",
                "com.anthropic.claudefordesktop" + ".helper"),
            ("/Applications/OpenClaw.app/Contents/MacOS/openclaw-mlx-tts", "openclaw-mlx-tts"),
            ("/Applications/PeekabooInspector.app/Contents/MacOS/PeekabooInspector", "boo.peekaboo.inspector"),
            ("/Applications/Playground.app/Contents/MacOS/Playground", "boo.peekaboo.playground.debug"),
            ("/tmp/PeekabooTestHost", "boo.peekaboo.peekaboo.testhost"),
            ("/tmp/Claude", "com.example.anthropic.claude.integration"),
            ("/tmp/OpenClaw", "com.example.openclaw.helper"),
            ("/tmp/Clawdbot", "com.example.clawdbot.helper"),
            ("/Applications/Claude.app/Contents/MacOS/Claude", "com.example.unrelated"),
        ]
        for nonHost in nonHosts {
            #expect(!ScreenCaptureKitOwnerLease.isPotentialPeekabooProcess(
                executablePath: nonHost.path,
                signingIdentifier: nonHost.signingIdentifier))
        }

        let fixture = try LeaseFixture(name: "unsigned-main-bundle")
        defer { fixture.removeLockPath() }
        let bundleURL = fixture.directoryURL.appendingPathComponent("OpenClaw.app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let executableDirectory = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let executableURL = executableDirectory.appendingPathComponent("OpenClaw", isDirectory: false)
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "ai.openclaw.mac",
                "CFBundleExecutable": "OpenClaw",
                "CFBundlePackageType": "APPL",
            ],
            format: .xml,
            options: 0)
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        #expect(FileManager.default.createFile(atPath: executableURL.path, contents: Data()))
        #expect(ScreenCaptureKitOwnerLease.isPotentialPeekabooProcess(
            executablePath: executableURL.path,
            signingIdentifier: nil))
        #expect(!ScreenCaptureKitOwnerLease.isPotentialPeekabooProcess(
            executablePath: executableDirectory.appendingPathComponent("openclaw-mlx-tts").path,
            signingIdentifier: nil))
    }

    @Test
    func `Marker cleanup removes only secure unlocked stale generations`() throws {
        let fixture = try LeaseFixture(name: "marker-cleanup")
        defer { fixture.removeLockPath() }
        let stale = ScreenCaptureKitOwnerLease.processCapabilityMarkerURL(
            processIdentifier: 999_999,
            processStartIdentity: 1,
            directory: fixture.directoryURL)
        let live = ScreenCaptureKitOwnerLease.processCapabilityMarkerURL(
            processIdentifier: getpid(),
            processStartIdentity: fixture.processStartIdentity,
            directory: fixture.directoryURL)
        let lockedStale = ScreenCaptureKitOwnerLease.processCapabilityMarkerURL(
            processIdentifier: 999_998,
            processStartIdentity: 1,
            directory: fixture.directoryURL)
        #expect(FileManager.default.createFile(atPath: stale.path, contents: Data("stale".utf8)))
        #expect(FileManager.default.createFile(atPath: live.path, contents: Data("live".utf8)))
        #expect(FileManager.default.createFile(atPath: lockedStale.path, contents: Data("locked".utf8)))
        #expect(chmod(stale.path, S_IRUSR | S_IWUSR) == 0)
        #expect(chmod(live.path, S_IRUSR | S_IWUSR) == 0)
        #expect(chmod(lockedStale.path, S_IRUSR | S_IWUSR) == 0)
        let lockedDescriptor = open(lockedStale.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        #expect(lockedDescriptor >= 0)
        if lockedDescriptor >= 0 {
            #expect(flock(lockedDescriptor, LOCK_EX | LOCK_NB) == 0)
        }
        defer {
            if lockedDescriptor >= 0 {
                flock(lockedDescriptor, LOCK_UN)
                close(lockedDescriptor)
            }
        }

        try ScreenCaptureKitOwnerLease.removeStaleProcessCapabilityMarkers(directory: fixture.directoryURL)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: live.path))
        #expect(FileManager.default.fileExists(atPath: lockedStale.path))
    }

    @Test
    func `Live identity records the current generation and an exact executable identity`() throws {
        let fixture = try LeaseFixture(name: "live-identity")
        defer { fixture.removeLockPath() }

        let result = try ScreenCaptureKitOwnerLease(
            lockURL: fixture.lockURL,
            ownerIdentity: .current()).claim()

        guard case let .acquired(receipt) = result else {
            Issue.record("Expected the live identity claim to acquire the lease")
            return
        }
        #expect(receipt.processIdentifier == getpid())
        #expect(receipt.processStartIdentity == fixture.processStartIdentity)
        #expect(receipt.buildIdentity?.isEmpty == false || receipt.codeSignatureHash?.isEmpty == false)
    }

    @Test
    func `Claim persists a secure receipt and same-process reentry preserves it`() throws {
        let fixture = try LeaseFixture(name: "reentry")
        defer { fixture.removeLockPath() }
        let lease = fixture.makeLease(buildIdentity: "test-build-a")

        let first = try lease.claim()
        let second = try fixture.makeLease(buildIdentity: "test-build-b").claim()

        guard case let .acquired(firstReceipt) = first else {
            Issue.record("Expected the first claim to acquire the lease")
            return
        }
        #expect(second == .alreadyOwnedByCurrentProcess(firstReceipt))
        #expect(try ScreenCaptureKitOwnerLease.currentOwnerReceiptIfHeld(lockURL: fixture.lockURL) == firstReceipt)
        #expect(firstReceipt.buildIdentity == "test-build-a")
        #expect(try fixture.persistedReceipt() == firstReceipt)

        var fileInfo = stat()
        #expect(lstat(fixture.lockURL.path, &fileInfo) == 0)
        #expect(fileInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
        #expect(fileInfo.st_uid == geteuid())
        #expect(fileInfo.st_nlink == 1)
        #expect(fileInfo.st_mode & mode_t(S_IRWXU | S_IRWXG | S_IRWXO) == mode_t(S_IRUSR | S_IWUSR))

        let heldDescriptor = try #require(self.descriptor(for: fileInfo))
        self.expectLiveCloseOnExecDescriptor(heldDescriptor, matching: fileInfo)
        #if compiler(>=6.4)
        #expect(peekaboo_probe_descriptor_after_fork(heldDescriptor) == DescriptorForkProbeClosed)
        #endif
        self.expectLiveCloseOnExecDescriptor(heldDescriptor, matching: fileInfo)
        #expect(try fixture.persistedReceipt() == firstReceipt)
        #expect(try fixture.makeLease(buildIdentity: "after-fork")
            .claim() == .alreadyOwnedByCurrentProcess(firstReceipt))

        let descriptor = open(fixture.lockURL.path, O_RDONLY | O_NOFOLLOW)
        #expect(descriptor >= 0)
        if descriptor >= 0 {
            defer { close(descriptor) }
            #expect(flock(descriptor, LOCK_EX | LOCK_NB) == -1)
            #expect(errno == EWOULDBLOCK || errno == EAGAIN)
        }
    }

    @Test
    func `Same-process reentry rescans late-starting uncoordinated hosts`() throws {
        let fixture = try LeaseFixture(name: "reentry-rescan")
        defer { fixture.removeLockPath() }
        let conflict = ScreenCaptureKitOwnerLease.UncoordinatedProcess(
            processIdentifier: 4242,
            processStartIdentity: 9001,
            executablePath: "/Applications/Claude.app/Contents/MacOS/Claude")
        let scanCount = OwnerLeaseScanCounter()
        let firstLease = ScreenCaptureKitOwnerLease(
            lockURL: fixture.lockURL,
            ownerIdentity: .init(
                processIdentifier: getpid(),
                processStartIdentity: fixture.processStartIdentity,
                buildIdentity: "current-build"),
            uncoordinatedProcesses: {
                scanCount.increment()
                return []
            })
        _ = try firstLease.claim()
        let reentrantLease = ScreenCaptureKitOwnerLease(
            lockURL: fixture.lockURL,
            ownerIdentity: .init(
                processIdentifier: getpid(),
                processStartIdentity: fixture.processStartIdentity,
                buildIdentity: "current-build"),
            uncoordinatedProcesses: {
                scanCount.increment()
                return [conflict]
            })

        #expect(throws: ScreenCaptureKitOwnerLease.LeaseError.uncoordinatedProcesses([conflict])) {
            try reentrantLease.claim()
        }
        #expect(scanCount.value == 2)
    }

    @Test
    func `Process capability preparation wait is bounded without cancelling its scan`() async throws {
        let gate = OwnerPreparationAsyncGate()
        let task = Task { () async throws in
            await gate.wait()
            try Task.checkCancellation()
        }
        await gate.waitUntilStarted()
        let clock = ContinuousClock()
        let startedAt = clock.now

        let error = await #expect(throws: ScreenCaptureKitOwnerLease.LeaseError.self) {
            try await ScreenCaptureKitOwnerLease.waitForProcessCapabilityPreparation(
                task,
                timeoutSeconds: 0.02)
        }

        #expect(error == .preparationTimedOut(seconds: 0.02))
        #expect(clock.now - startedAt < .seconds(1))
        await gate.release()
        try await task.value
    }

    @Test
    func `Process capability preparation warms validation without claiming and leaf rescans`() throws {
        let fixture = try LeaseFixture(name: "preparation-does-not-claim")
        defer { fixture.removeLockPath() }
        let scanCount = OwnerLeaseScanCounter()
        let lease = ScreenCaptureKitOwnerLease(
            lockURL: fixture.lockURL,
            ownerIdentity: .init(
                processIdentifier: getpid(),
                processStartIdentity: fixture.processStartIdentity,
                buildIdentity: "current-build"),
            uncoordinatedProcesses: {
                scanCount.increment()
                return []
            })

        try lease.prepareForClaim()

        #expect(scanCount.value == 1)
        #expect(try ScreenCaptureKitOwnerLease.currentOwnerReceiptIfHeld(lockURL: fixture.lockURL) == nil)
        _ = try lease.claim()
        #expect(scanCount.value == 2)
        #expect(try ScreenCaptureKitOwnerLease.currentOwnerReceiptIfHeld(lockURL: fixture.lockURL) != nil)
    }

    @Test
    func `Same-process reentry fails closed if the lock path no longer names the held inode`() throws {
        let fixture = try LeaseFixture(name: "replaced-path")
        defer { fixture.removeLockPath() }
        _ = try fixture.makeLease(buildIdentity: "original-build").claim()
        try FileManager.default.removeItem(at: fixture.lockURL)
        #expect(FileManager.default.createFile(atPath: fixture.lockURL.path, contents: Data()))
        #expect(chmod(fixture.lockURL.path, S_IRUSR | S_IWUSR) == 0)

        #expect(throws: ScreenCaptureKitOwnerLease.LeaseError.unsafeLockFile(path: fixture.lockURL.path)) {
            try fixture.makeLease(buildIdentity: "replacement-build").claim()
        }
    }

    @Test
    func `Dropping the lease object does not release process-lifetime ownership`() throws {
        let fixture = try LeaseFixture(name: "lifetime")
        defer { fixture.removeLockPath() }

        try autoreleasepool {
            _ = try fixture.makeLease(buildIdentity: "process-lifetime").claim()
        }

        let contender = open(fixture.lockURL.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        #expect(contender >= 0)
        if contender >= 0 {
            defer { close(contender) }
            #expect(flock(contender, LOCK_EX | LOCK_NB) == -1)
            #expect(errno == EWOULDBLOCK || errno == EAGAIN)
        }
    }

    @Test
    func `Stale unlocked receipt is reclaimed and replaced`() throws {
        let fixture = try LeaseFixture(name: "stale")
        defer { fixture.removeLockPath() }
        let stale = ScreenCaptureKitOwnerLease.OwnerReceipt(identity: .init(
            processIdentifier: getpid(),
            processStartIdentity: fixture.processStartIdentity,
            buildIdentity: "stale-build"))
        try fixture.write(receipt: stale)

        let claim = try fixture.makeLease(buildIdentity: "fresh-build").claim()

        guard case let .acquired(receipt) = claim else {
            Issue.record("Expected an unlocked file to be reclaimed")
            return
        }
        #expect(receipt.buildIdentity == "fresh-build")
        #expect(try fixture.persistedReceipt() == receipt)
    }

    @Test
    func `Live subprocess receipt fails immediately then process exit releases ownership`() async throws {
        let fixture = try LeaseFixture(name: "subprocess")
        defer { fixture.removeLockPath() }
        let child = try fixture.startHoldingSubprocess()
        defer { child.stop() }
        let childGeneration = try await self.processStartIdentity(for: child.process.processIdentifier)
        let childReceipt = ScreenCaptureKitOwnerLease.OwnerReceipt(identity: .init(
            processIdentifier: child.process.processIdentifier,
            processStartIdentity: childGeneration,
            codeSignatureHash: "child-signature"))
        try child.install(receipt: childReceipt)
        #expect(try ScreenCaptureKitOwnerLease.currentOwnerReceiptIfHeld(lockURL: fixture.lockURL) == childReceipt)

        let startedAt = ContinuousClock.now
        do {
            _ = try fixture.makeLease(buildIdentity: "contender-build").claim()
            Issue.record("Expected the live owner to refuse the contender")
        } catch let error as ScreenCaptureKitOwnerLease.LeaseError {
            #expect(error == .ownedByAnotherProcess(path: fixture.lockURL.path, receipt: childReceipt))
        }
        #expect(startedAt.duration(to: .now) < .milliseconds(100))

        try child.stopAndWait()
        #expect(try ScreenCaptureKitOwnerLease.currentOwnerReceiptIfHeld(lockURL: fixture.lockURL) == nil)
        let recovered = try fixture.makeLease(buildIdentity: "recovered-build").claim()
        guard case let .acquired(receipt) = recovered else {
            Issue.record("Expected process exit to release the owner lease")
            return
        }
        #expect(receipt.buildIdentity == "recovered-build")
    }

    @Test
    func `Read-only probe ignores an unlocked stale receipt`() throws {
        let fixture = try LeaseFixture(name: "unlocked-probe")
        defer { fixture.removeLockPath() }
        let stale = ScreenCaptureKitOwnerLease.OwnerReceipt(identity: .init(
            processIdentifier: getpid(),
            processStartIdentity: fixture.processStartIdentity,
            buildIdentity: "unlocked-build"))
        try fixture.write(receipt: stale)

        #expect(try ScreenCaptureKitOwnerLease.currentOwnerReceiptIfHeld(lockURL: fixture.lockURL) == nil)

        let descriptor = open(fixture.lockURL.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        #expect(descriptor >= 0)
        if descriptor >= 0 {
            defer { close(descriptor) }
            #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
            #expect(flock(descriptor, LOCK_UN) == 0)
        }
    }

    @Test
    func `Contender rejects malformed or stale receipts while leaving the live lock untouched`() async throws {
        let fixture = try LeaseFixture(name: "invalid-receipt")
        defer { fixture.removeLockPath() }
        let child = try fixture.startHoldingSubprocess()
        defer { child.stop() }
        let childGeneration = try await self.processStartIdentity(for: child.process.processIdentifier)
        let staleReceipt = ScreenCaptureKitOwnerLease.OwnerReceipt(identity: .init(
            processIdentifier: child.process.processIdentifier,
            processStartIdentity: childGeneration + 1,
            buildIdentity: "stale-generation"))
        try child.install(receipt: staleReceipt)

        do {
            _ = try fixture.makeLease(buildIdentity: "contender-build").claim()
            Issue.record("Expected the stale receipt to fail closed")
        } catch let error as ScreenCaptureKitOwnerLease.LeaseError {
            guard case let .invalidOwnerReceipt(path, reason) = error else {
                Issue.record("Expected invalidOwnerReceipt, got \(error)")
                return
            }
            #expect(path == fixture.lockURL.path)
            #expect(reason == "stale process generation")
        }
    }

    @Test
    func `Symlinks and multiply-linked files fail closed`() throws {
        let symlinkFixture = try LeaseFixture(name: "symlink")
        defer { symlinkFixture.removeLockPath() }
        let destination = symlinkFixture.directoryURL.appendingPathComponent("destination")
        #expect(FileManager.default.createFile(atPath: destination.path, contents: Data()))
        try FileManager.default.createSymbolicLink(at: symlinkFixture.lockURL, withDestinationURL: destination)

        do {
            _ = try symlinkFixture.makeLease(buildIdentity: "symlink-build").claim()
            Issue.record("Expected O_NOFOLLOW to reject a symlink")
        } catch let error as ScreenCaptureKitOwnerLease.LeaseError {
            #expect(error == .systemCall(operation: "open", path: symlinkFixture.lockURL.path, code: ELOOP))
        }

        let hardlinkFixture = try LeaseFixture(name: "hardlink")
        defer { hardlinkFixture.removeLockPath() }
        #expect(FileManager.default.createFile(atPath: hardlinkFixture.lockURL.path, contents: Data()))
        let secondLink = hardlinkFixture.directoryURL.appendingPathComponent("second-link")
        #expect(link(hardlinkFixture.lockURL.path, secondLink.path) == 0)

        do {
            _ = try hardlinkFixture.makeLease(buildIdentity: "hardlink-build").claim()
            Issue.record("Expected a multiply-linked lock file to be rejected")
        } catch let error as ScreenCaptureKitOwnerLease.LeaseError {
            #expect(error == .unsafeLockFile(path: hardlinkFixture.lockURL.path))
        }
    }

    @Test
    func `Injected identity must describe the current process generation and a build`() throws {
        let fixture = try LeaseFixture(name: "identity")
        defer { fixture.removeLockPath() }
        let missingBuild = ScreenCaptureKitOwnerLease(
            lockURL: fixture.lockURL,
            ownerIdentity: .init(
                processIdentifier: getpid(),
                processStartIdentity: fixture.processStartIdentity),
            processStartIdentity: { _ in fixture.processStartIdentity })
        #expect(throws: ScreenCaptureKitOwnerLease.LeaseError.invalidOwnerIdentity(
            "a build or code-signature identity is required"))
        {
            try missingBuild.claim()
        }

        let wrongGeneration = ScreenCaptureKitOwnerLease(
            lockURL: fixture.lockURL,
            ownerIdentity: .init(
                processIdentifier: getpid(),
                processStartIdentity: fixture.processStartIdentity + 1,
                buildIdentity: "test-build"),
            processStartIdentity: { _ in fixture.processStartIdentity })
        #expect(throws: ScreenCaptureKitOwnerLease.LeaseError.invalidOwnerIdentity(
            "the receipt process generation is not current"))
        {
            try wrongGeneration.claim()
        }
    }

    private func processStartIdentity(for processIdentifier: pid_t) async throws -> UInt64 {
        for _ in 0..<100 {
            if let identity = SystemIdentityResolver.processStartIdentity(processIdentifier) {
                return identity
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TestError("Could not resolve child process generation")
    }

    private func expectLiveCloseOnExecDescriptor(_ descriptor: Int32, matching expectedInfo: stat) {
        let flags = fcntl(descriptor, F_GETFD)
        #expect(flags >= 0)
        #expect(flags & FD_CLOEXEC == FD_CLOEXEC)
        var fileInfo = stat()
        #expect(fstat(descriptor, &fileInfo) == 0)
        #expect(fileInfo.st_dev == expectedInfo.st_dev)
        #expect(fileInfo.st_ino == expectedInfo.st_ino)
    }

    private func descriptor(for expectedInfo: stat) -> Int32? {
        for descriptor in 0..<getdtablesize() {
            var candidateInfo = stat()
            guard fstat(descriptor, &candidateInfo) == 0 else { continue }
            if candidateInfo.st_dev == expectedInfo.st_dev,
               candidateInfo.st_ino == expectedInfo.st_ino
            {
                return descriptor
            }
        }
        return nil
    }
}

private struct LeaseFixture {
    let directoryURL: URL
    let lockURL: URL
    let processStartIdentity: UInt64

    init(name: String) throws {
        self.directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-sck-owner-tests-\(name)-\(UUID().uuidString)", isDirectory: true)
        self.lockURL = self.directoryURL.appendingPathComponent("owner.lock")
        self.processStartIdentity = try SystemIdentityResolver.processStartIdentity(getpid())
            .unwrap(or: TestError("Could not resolve test process generation"))
        try FileManager.default.createDirectory(
            at: self.directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: S_IRWXU)])
    }

    func makeLease(buildIdentity: String) -> ScreenCaptureKitOwnerLease {
        ScreenCaptureKitOwnerLease(
            lockURL: self.lockURL,
            ownerIdentity: .init(
                processIdentifier: getpid(),
                processStartIdentity: self.processStartIdentity,
                buildIdentity: buildIdentity),
            processStartIdentity: SystemIdentityResolver.processStartIdentity,
            registerProcessCapability: {},
            uncoordinatedProcesses: { [] },
            uncoordinatedHosts: { [] })
    }

    func write(receipt: ScreenCaptureKitOwnerLease.OwnerReceipt) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(receipt).write(to: self.lockURL)
        #expect(chmod(self.lockURL.path, S_IRUSR | S_IWUSR) == 0)
    }

    func persistedReceipt() throws -> ScreenCaptureKitOwnerLease.OwnerReceipt {
        try JSONDecoder().decode(
            ScreenCaptureKitOwnerLease.OwnerReceipt.self,
            from: Data(contentsOf: self.lockURL))
    }

    func startHoldingSubprocess() throws -> HoldingSubprocess {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            """
            import fcntl, os, sys
            path = sys.argv[1]
            descriptor = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            print("locked", flush=True)
            receipt = sys.stdin.buffer.readline().rstrip(b"\\n")
            os.ftruncate(descriptor, 0)
            os.pwrite(descriptor, receipt, 0)
            os.fsync(descriptor)
            print("ready", flush=True)
            sys.stdin.buffer.readline()
            """,
            self.lockURL.path,
        ]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        let readiness = try output.fileHandleForReading.read(upToCount: 7)
        guard readiness.flatMap({ String(bytes: $0, encoding: .utf8) }) == "locked\n" else {
            process.terminate()
            throw TestError("Lock subprocess did not become ready")
        }
        return HoldingSubprocess(process: process, input: input, output: output)
    }

    func removeLockPath() {
        try? FileManager.default.removeItem(at: self.directoryURL)
    }
}

private final class HoldingSubprocess {
    let process: Process
    private let input: Pipe
    private let output: Pipe
    private var stopped = false

    init(process: Process, input: Pipe, output: Pipe) {
        self.process = process
        self.input = input
        self.output = output
    }

    func install(receipt: ScreenCaptureKitOwnerLease.OwnerReceipt) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(receipt)
        data.append(0x0A)
        try self.input.fileHandleForWriting.write(contentsOf: data)
        let readiness = try self.output.fileHandleForReading.read(upToCount: 6)
        guard readiness.flatMap({ String(bytes: $0, encoding: .utf8) }) == "ready\n" else {
            throw TestError("Lock subprocess did not install its receipt")
        }
    }

    func stopAndWait() throws {
        guard !self.stopped else { return }
        self.stopped = true
        try self.input.fileHandleForWriting.write(contentsOf: Data([0x0A]))
        try self.input.fileHandleForWriting.close()
        self.process.waitUntilExit()
        guard self.process.terminationStatus == 0 else {
            throw TestError("Lock subprocess exited with \(self.process.terminationStatus)")
        }
    }

    func stop() {
        guard !self.stopped else { return }
        self.stopped = true
        try? self.input.fileHandleForWriting.close()
        if self.process.isRunning {
            self.process.terminate()
            self.process.waitUntilExit()
        }
    }
}

private final class OwnerLeaseScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        self.lock.withLock { self.count }
    }

    func increment() {
        self.lock.withLock {
            self.count += 1
        }
    }
}

private actor OwnerPreparationAsyncGate {
    private var didStart = false
    private var didRelease = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        self.didStart = true
        self.startWaiters.forEach { $0.resume() }
        self.startWaiters.removeAll()
        guard !self.didRelease else { return }
        await withCheckedContinuation { continuation in
            self.releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !self.didStart else { return }
        await withCheckedContinuation { continuation in
            self.startWaiters.append(continuation)
        }
    }

    func release() {
        self.didRelease = true
        self.releaseWaiters.forEach { $0.resume() }
        self.releaseWaiters.removeAll()
    }
}

private struct TestError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

extension Optional {
    fileprivate func unwrap(or error: @autoclosure () -> any Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
