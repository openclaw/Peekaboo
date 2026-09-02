import CoreGraphics
import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
struct ApplicationInventoryTimeoutTests {
    @Test(arguments: NativeInventoryPhase.allCases, [false, true])
    func `blocked native inventory phases release callers and MainActor without releasing native work`(
        phase: NativeInventoryPhase,
        cancel: Bool) async throws
    {
        let gate = ApplicationInventoryBlockingGate()
        defer { gate.release() }
        let nativeReads = AutomationTestLockedValue(0)
        let heartbeat = AutomationTestLockedValue(false)
        let service = await Self.blockedInventoryService(phase: phase, cancel: cancel, gate: gate, reads: nativeReads)
        let task = Task { try await phase.observe(service) }
        #expect(await gate.startedAsynchronously())
        let beat = Task { @MainActor in heartbeat.value = !gate.wasReleased }
        if cancel {
            task.cancel()
        }
        do {
            _ = try await task.value
            Issue.record("Blocked \(phase.rawValue) must throw before publishing inventory")
        } catch is CancellationError {
            #expect(cancel)
        } catch let error as PeekabooError {
            guard case .timeout = error else { throw error }
            #expect(!cancel)
        }
        await beat.value
        #expect(heartbeat.value)
        #expect(!gate.wasReleased)

        if !gate.wasReleased {
            let newerReads = AutomationTestLockedValue(0)
            let newerService = await MainActor.run {
                ApplicationService(
                    applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
                    frontmostProcessIdentifierProvider: { nil },
                    runningApplicationProcessIdentifiersProvider: {
                        newerReads.withValue { $0 += 1 }
                        return []
                    },
                    applicationWindowCatalogProvider: { [] })
            }
            for _ in 0..<3 {
                await #expect(throws: PeekabooError.self) { _ = try await newerService.listApplications() }
                await #expect(throws: PeekabooError.self) { _ = try await newerService.applicationMutationInventory() }
            }
            let newerRequest = Task { try await phase.observe(newerService) }
            await #expect(throws: PeekabooError.self) { _ = try await newerRequest.value }
            #expect(nativeReads.value == 1)
            #expect(newerReads.value == 0)
            gate.release()
            #expect(gate.waitUntilFinished())
            // Both callers retain their terminal failure when the old native value arrives late.
            if cancel {
                await #expect(throws: CancellationError.self) { _ = try await task.value }
            } else {
                await #expect(throws: PeekabooError.self) { _ = try await task.value }
            }
            await #expect(throws: PeekabooError.self) { _ = try await newerRequest.value }
            #expect(newerReads.value == 0)
            // The provider's finished signal precedes native-slot release; observe recovery before the next case.
            let recoveryDeadline = ContinuousClock.now.advanced(by: .seconds(1))
            while true {
                do {
                    let recovered = try await newerService.listApplications()
                    #expect(recovered.data.applications.isEmpty)
                    #expect(recovered.metadata.warnings.isEmpty)
                    break
                } catch let error as PeekabooError {
                    guard case .timeout = error, ContinuousClock.now < recoveryDeadline else { throw error }
                    await Task.yield()
                }
            }
            return
        }
        gate.release()
        #expect(gate.waitUntilFinished())
    }

    @Test
    @MainActor
    func `PID discovery consumes the overall budget before empty inventory can be complete`() async throws {
        let clock = AutomationTestLockedValue(ContinuousClock.now)
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
            frontmostProcessIdentifierProvider: { nil },
            runningApplicationProcessIdentifiersProvider: {
                clock.withValue { $0 = $0.advanced(by: .seconds(2)) }
                return []
            },
            applicationWindowCatalogProvider: { [] },
            applicationInventoryNowProvider: { clock.value })
        await #expect(throws: PeekabooError.self) { _ = try await service.listApplications() }
        await #expect(throws: PeekabooError.self) { _ = try await service.applicationMutationInventory() }
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(applications: service)
        await #expect(throws: DesktopTargetPlanningError.applicationInventoryUnavailable(identifier: "Editor")) {
            _ = try await planner.plan(identifier: "Editor")
        }
    }

    @Test
    @MainActor
    func `omitted and identity-incomplete live processes make inventory partial`() async throws {
        let changedPID: pid_t = 40001
        let missingIdentityPID: pid_t = 40002
        let changedGeneration = AutomationTestLockedValue<UInt64>(70)
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
            frontmostProcessIdentifierProvider: { nil },
            processStartIdentityProvider: { pid in
                pid == changedPID ? changedGeneration.value : nil
            },
            runningApplicationProcessIdentifiersProvider: { [changedPID, missingIdentityPID] },
            applicationWindowCatalogProvider: { [] },
            applicationMetadataProvider: { pid, _, _ in
                if pid == changedPID {
                    changedGeneration.value = 71
                }
                return Self.metadata(name: "App \(pid)")
            })

        let output = try await service.listApplications()

        #expect(output.data.applications.map(\.processIdentifier) == [missingIdentityPID])
        #expect(output.summary.status == .partial)
        #expect(output.summary.counts["incompleteApplications"] == 1)
        #expect(output.summary.counts["omittedApplications"] == 1)
        #expect(output.metadata.warnings.contains { $0.contains("changed process generation") })
        #expect(output.metadata.warnings.contains { $0.contains("Process-generation identity was unavailable") })
    }

    @Test
    @MainActor
    func `metadata without a usable name records an omitted inventory row`() async throws {
        let pid: pid_t = 40003
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
            frontmostProcessIdentifierProvider: { nil },
            processStartIdentityProvider: { _ in 73 },
            runningApplicationProcessIdentifiersProvider: { [pid] },
            applicationWindowCatalogProvider: { [] },
            applicationMetadataProvider: { _, _, _ in
                DetachedApplicationMetadata(
                    bundleIdentifier: "com.example.unnamed",
                    name: nil,
                    bundlePath: nil,
                    isHidden: false,
                    activationPolicy: .regular,
                    isFinishedLaunching: true)
            })

        let output = try await service.listApplications()

        #expect(output.data.applications.isEmpty)
        #expect(output.summary.status == .partial)
        #expect(output.summary.counts["incompleteApplications"] == 0)
        #expect(output.summary.counts["omittedApplications"] == 1)
        #expect(output.metadata.warnings == ["Application PID \(pid) metadata lacked a usable name and was omitted."])
    }

    @Test
    @MainActor
    func `mutation inventory uses only selector fields and skips presentation enrichment`() async throws {
        let pid: pid_t = 40004
        let application = ServiceApplicationInfo(
            processIdentifier: pid,
            processStartIdentity: 74,
            bundleIdentifier: "com.example.fixture",
            name: "Editor")
        let windowCatalogReadCount = AutomationTestLockedValue(0)
        let metadataReadCount = AutomationTestLockedValue(0)
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
            applicationMutationCandidateProvider: { _ in
                ApplicationIdentifierMatcher.Candidate(
                    processIdentifier: pid,
                    bundleIdentifier: "com.example.fixture",
                    name: "Editor",
                    isRegularApplication: true)
            },
            frontmostProcessIdentifierProvider: { nil },
            processStartIdentityProvider: { _ in 74 },
            runningApplicationProcessIdentifiersProvider: { [pid] },
            applicationWindowCatalogProvider: {
                windowCatalogReadCount.withValue { $0 += 1 }
                return nil
            },
            applicationMetadataProvider: { _, _, _ in
                metadataReadCount.withValue { $0 += 1 }
                return Self.metadata(name: "Editor")
            })
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { try await service.applicationMutationInventory() },
            exactIdentifierProvider: { _ in application })

        let byName = try await planner.plan(identifier: "Editor")
        let byBundle = try await planner.plan(identifier: "com.example.fixture")

        #expect(byName.processIdentity == application.processIdentity)
        #expect(byBundle.processIdentity == application.processIdentity)
        #expect(windowCatalogReadCount.value == 0)
        #expect(metadataReadCount.value == 0)
    }

    @Test
    @MainActor
    func `mutation inventory reports missing and drifting process generations as partial`() async throws {
        let stablePID: pid_t = 40005
        let missingPID: pid_t = 40006
        let driftingPID: pid_t = 40007
        let driftingReads = AutomationTestLockedValue(0)
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
            applicationMutationCandidateProvider: { pid in
                ApplicationIdentifierMatcher.Candidate(
                    processIdentifier: pid,
                    bundleIdentifier: "com.example.\(pid)",
                    name: "App \(pid)")
            },
            frontmostProcessIdentifierProvider: { nil },
            processStartIdentityProvider: { pid -> UInt64? in
                switch pid {
                case stablePID: 75
                case missingPID: nil
                case driftingPID:
                    driftingReads.withValue {
                        $0 += 1
                        return $0 == 1 ? 76 : 77
                    }
                default: nil
                }
            },
            runningApplicationProcessIdentifiersProvider: { [stablePID, missingPID, driftingPID] })

        let inventory = try await service.applicationMutationInventory()

        #expect(inventory.items.map(\.processIdentifier) == [stablePID])
        #expect(!inventory.isComplete)
        #expect(inventory.warnings == [
            "Application PID \(missingPID) lacked process-generation identity and was omitted.",
            "Application PID \(driftingPID) changed process generation during inventory and was omitted.",
        ])
    }

    @Test
    @MainActor
    func `mutation inventory omits a live process without a usable selector name`() async throws {
        let namedPID: pid_t = 40008
        let unnamedPID: pid_t = 40009
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
            applicationMutationCandidateProvider: { pid in
                ApplicationIdentifierMatcher.Candidate(
                    processIdentifier: pid,
                    bundleIdentifier: "com.example.\(pid)",
                    name: pid == unnamedPID ? "  \n" : "Named App")
            },
            frontmostProcessIdentifierProvider: { nil },
            processStartIdentityProvider: { pid in UInt64(pid) + 100 },
            runningApplicationProcessIdentifiersProvider: { [namedPID, unnamedPID] })

        let inventory = try await service.applicationMutationInventory()

        #expect(inventory.items.map(\.processIdentifier) == [namedPID])
        #expect(!inventory.isComplete)
        #expect(inventory.warnings == [
            "Application PID \(unnamedPID) metadata lacked a usable name and was omitted.",
        ])
    }

    @Test
    @MainActor
    func `one timed out process returns truthful partial inventory without dropping other apps`() async throws {
        let healthyPID: pid_t = 41001
        let poisonedPID: pid_t = 41002
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
            frontmostProcessIdentifierProvider: { nil },
            processStartIdentityProvider: { pid in UInt64(pid) + 100 },
            runningApplicationProcessIdentifiersProvider: { [healthyPID, poisonedPID] },
            applicationWindowCatalogProvider: {
                [
                    Self.window(id: 101, pid: healthyPID, appName: "Healthy Hidden App"),
                    Self.window(id: 202, pid: poisonedPID, appName: "Poisoned Hidden Helper"),
                ]
            },
            applicationMetadataProvider: { pid, _, timeout in
                if pid == poisonedPID {
                    throw CaptureError.detectionTimedOut(timeout)
                }
                return DetachedApplicationMetadata(
                    bundleIdentifier: "com.example.healthy",
                    name: "Healthy Hidden App",
                    bundlePath: "/Applications/Healthy Hidden App.app",
                    isHidden: true,
                    activationPolicy: .regular,
                    isFinishedLaunching: true)
            },
            applicationMetadataTimeout: 0.05)

        let output = try await service.listApplications()
        let healthy = try #require(output.data.applications.first { $0.processIdentifier == healthyPID })
        let poisoned = try #require(output.data.applications.first { $0.processIdentifier == poisonedPID })

        #expect(healthy.isHidden)
        #expect(healthy.isHiddenKnown == true)
        #expect(healthy.windowIDs == [101])
        #expect(healthy.metadataWarnings == nil)
        #expect(poisoned.name == "Poisoned Hidden Helper")
        #expect(!poisoned.isHidden)
        #expect(poisoned.isHiddenKnown == false)
        #expect(poisoned.activationPolicy == nil)
        #expect(poisoned.windowIDs == [202])
        #expect(poisoned.metadataWarnings?.contains { $0.contains("timed out after 0.05s") } == true)
        #expect(output.summary.status == .partial)
        #expect(output.summary.counts["incompleteApplications"] == 1)
        #expect(output.metadata.warnings == poisoned.metadataWarnings)
    }

    @Test
    @MainActor
    func `cancelled global inventory publishes no partial result`() async throws {
        let started = ApplicationInventoryGate()
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
            frontmostProcessIdentifierProvider: { nil },
            processStartIdentityProvider: { _ in 7 },
            runningApplicationProcessIdentifiersProvider: { [42001, 42002] },
            applicationWindowCatalogProvider: { [] },
            applicationMetadataProvider: { _, _, _ in
                await started.markStarted()
                try await Task.sleep(for: .seconds(30))
                throw ApplicationInventoryFixtureError.unused
            },
            applicationMetadataTimeout: 30)

        let task = Task { @MainActor in
            try await service.listApplications()
        }
        await started.wait()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test
    @MainActor
    func `async-await metadata fanout obeys its concurrency cap independently of native retention`() async throws {
        let processIdentifiers = Array(44001...44012).map(pid_t.init)
        let probe = ApplicationMetadataConcurrencyProbe()
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
            frontmostProcessIdentifierProvider: { nil },
            processStartIdentityProvider: { _ in 7 },
            runningApplicationProcessIdentifiersProvider: { processIdentifiers },
            applicationWindowCatalogProvider: { [] },
            applicationMetadataProvider: { pid, _, _ in
                await probe.enterAndWait()
                return Self.metadata(name: "App \(pid)")
            },
            applicationMetadataTimeout: 5,
            maximumConcurrentApplicationMetadataReads: 3)

        let task = Task { @MainActor in
            try await service.listApplications()
        }
        await probe.waitUntilEntered(3)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await probe.maximumInFlight == 3)
        #expect(await probe.totalEntered == 3)
        await probe.releaseAll()

        let output = try await task.value
        #expect(output.data.applications.count == processIdentifiers.count)
        #expect(await probe.maximumInFlight == 3)
    }

    @Test
    @MainActor
    func `many-process inventory waits for one bound rather than summing every process timeout`() async throws {
        let processIdentifiers = Array(45001...45064).map(pid_t.init)
        let poisonedPID = processIdentifiers[2]
        let lateWorker = ApplicationInventoryBlockingGate()
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
            frontmostProcessIdentifierProvider: { nil },
            processStartIdentityProvider: { pid in UInt64(pid) + 10 },
            runningApplicationProcessIdentifiersProvider: { Array(processIdentifiers.reversed()) },
            applicationWindowCatalogProvider: { [] },
            applicationMetadataProvider: { pid, generation, timeout in
                try await DetachedApplicationMetadataCoordinator.run(
                    processIdentifier: pid,
                    processStartIdentity: generation,
                    timeoutSeconds: timeout)
                { _ in
                    if pid == poisonedPID {
                        lateWorker.markStarted()
                        lateWorker.wait()
                        lateWorker.markFinished()
                    }
                    return Self.metadata(name: String(format: "App %05d", pid))
                }
            },
            applicationMetadataTimeout: 0.05,
            maximumConcurrentApplicationMetadataReads: 8)

        let startedAt = ContinuousClock.now
        let output = try await service.listApplications()
        let elapsed = startedAt.duration(to: .now).timeInterval
        let poisoned = try #require(output.data.applications.first { $0.processIdentifier == poisonedPID })

        #expect(elapsed < 0.5)
        #expect(output.data.applications.count == processIdentifiers.count)
        #expect(output.data.applications.map(\.name) == output.data.applications.map(\.name).sorted())
        #expect(poisoned.isHiddenKnown == false)
        #expect(poisoned.metadataWarnings?.contains { $0.contains("timed out") } == true)

        lateWorker.release()
        #expect(lateWorker.waitUntilFinished())
        // The detached worker completed too late to mutate the already-published value.
        #expect(poisoned.isHiddenKnown == false)
        #expect(poisoned.metadataWarnings?.contains { $0.contains("timed out") } == true)
    }

    @Test
    @MainActor
    func `overall deadline refuses an inventory that cannot finish observation`() async throws {
        let processIdentifiers = Array(46001...46128).map(pid_t.init)
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
            frontmostProcessIdentifierProvider: { nil },
            processStartIdentityProvider: { pid in UInt64(pid) + 10 },
            runningApplicationProcessIdentifiersProvider: { processIdentifiers },
            applicationWindowCatalogProvider: { [] },
            applicationMetadataProvider: { _, _, timeout in
                try await Task.sleep(for: .milliseconds(50))
                throw CaptureError.detectionTimedOut(timeout)
            },
            applicationMetadataTimeout: 0.05,
            applicationInventoryOverallTimeout: 0.11,
            maximumConcurrentApplicationMetadataReads: 8)

        await #expect(throws: PeekabooError.self) { _ = try await service.listApplications() }
    }

    @Test
    @MainActor
    func `metadata reads launched near the overall deadline receive only its remaining budget`() async throws {
        let processIdentifiers: [pid_t] = [47001, 47002]
        let clockStart = ContinuousClock.now
        let clock = AutomationTestLockedValue(clockStart)
        let timeoutRecorder = ApplicationMetadataTimeoutRecorder()
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
            frontmostProcessIdentifierProvider: { nil },
            processStartIdentityProvider: { pid in UInt64(pid) + 10 },
            runningApplicationProcessIdentifiersProvider: { processIdentifiers },
            applicationWindowCatalogProvider: { [] },
            applicationInventoryNowProvider: { clock.value },
            applicationMetadataProvider: { pid, _, timeout in
                await timeoutRecorder.record(processIdentifier: pid, timeout: timeout)
                clock.value = clockStart.advanced(by: .milliseconds(90))
                return Self.metadata(name: "App \(pid)")
            },
            applicationMetadataTimeout: 0.5,
            applicationInventoryOverallTimeout: 0.1,
            maximumConcurrentApplicationMetadataReads: 1)

        let output = try await service.listApplications()
        let recordedTimeouts = await timeoutRecorder.timeouts

        #expect(output.data.applications.count == processIdentifiers.count)
        #expect(recordedTimeouts.count == processIdentifiers.count)
        #expect(abs(recordedTimeouts[0] - 0.1) < 0.001)
        #expect(abs(recordedTimeouts[1] - 0.01) < 0.001)
    }

    @Test
    func `noncooperative per-process metadata times out without holding caller`() async throws {
        let gate = ApplicationInventoryBlockingGate()
        let startedAt = ContinuousClock.now

        await #expect(throws: CaptureError.self) {
            _ = try await DetachedApplicationMetadataCoordinator.run(
                processIdentifier: 43001,
                processStartIdentity: nil,
                timeoutSeconds: 0.05)
            { _ in
                gate.markStarted()
                gate.wait()
                return Self.metadata(name: "Late")
            }
        }

        #expect(startedAt.duration(to: .now).timeInterval < 0.5)
        gate.release()
    }

    @Test
    func `repeated inventory does not enqueue behind a still-blocked process lane`() async throws {
        let gate = ApplicationInventoryBlockingGate()
        let repeatedStarted = ApplicationInventoryFlag()

        await #expect(throws: CaptureError.self) {
            _ = try await DetachedApplicationMetadataCoordinator.run(
                processIdentifier: 43003,
                processStartIdentity: nil,
                timeoutSeconds: 0.05)
            { _ in
                gate.markStarted()
                gate.wait()
                gate.markFinished()
                return Self.metadata(name: "Late")
            }
        }

        let repeatedStartedAt = ContinuousClock.now
        await #expect(throws: CaptureError.self) {
            _ = try await DetachedApplicationMetadataCoordinator.run(
                processIdentifier: 43003,
                processStartIdentity: nil,
                timeoutSeconds: 0.05)
            { _ in
                repeatedStarted.set()
                return Self.metadata(name: "Duplicate")
            }
        }
        #expect(repeatedStartedAt.duration(to: .now).timeInterval < 0.1)
        #expect(!repeatedStarted.value)

        gate.release()
        #expect(gate.waitUntilFinished())
    }

    @Test
    func `cancelled noncooperative metadata returns while detached lane finishes later`() async throws {
        let gate = ApplicationInventoryBlockingGate()
        let task = Task {
            try await DetachedApplicationMetadataCoordinator.run(
                processIdentifier: 43002,
                processStartIdentity: nil,
                timeoutSeconds: 30)
            { _ in
                gate.markStarted()
                gate.wait()
                return Self.metadata(name: "Late")
            }
        }
        #expect(gate.waitUntilStarted())

        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        gate.release()
    }

    enum NativeInventoryPhase: String, CaseIterable, Sendable {
        case listingPID, listingCatalog, listingFinalGeneration
        case mutationPID, mutationSelector, mutationFinalGeneration
        case mutationEligibility, mutationEligibilityRecheck, mutationDeniedGenerationRecheck

        var readsDeniedGeneration: Bool {
            switch self {
            case .mutationEligibility, .mutationEligibilityRecheck, .mutationDeniedGenerationRecheck: true
            default: false
            }
        }

        @MainActor
        func observe(_ service: ApplicationService) async throws -> [ServiceApplicationInfo] {
            switch self {
            case .listingPID, .listingCatalog, .listingFinalGeneration:
                try await service.listApplications().data.applications
            case .mutationPID, .mutationSelector, .mutationFinalGeneration,
                 .mutationEligibility, .mutationEligibilityRecheck, .mutationDeniedGenerationRecheck:
                try await service.applicationMutationInventory().items
            }
        }
    }

    @MainActor
    private static func blockedInventoryService(
        phase: NativeInventoryPhase,
        cancel: Bool,
        gate: ApplicationInventoryBlockingGate,
        reads: AutomationTestLockedValue<Int>) -> ApplicationService
    {
        let pid: pid_t = 42003
        let generationReads = AutomationTestLockedValue(0)
        let selectorReads = AutomationTestLockedValue(0)
        let metadataReads = AutomationTestLockedValue(0)
        let eligibilityReads = AutomationTestLockedValue(0)
        let block: @Sendable (NativeInventoryPhase) -> Void = { boundary in
            guard phase == boundary else { return }
            reads.withValue { $0 += 1 }
            gate.markStarted()
            gate.waitWithEmergencyRelease()
            gate.markFinished()
        }
        let deniedIdentityProvider: ApplicationService.MutationIdentityObservationProvider = { identifier in
            #expect(identifier == pid)
            let read = generationReads.withValue { $0 += 1; return $0 }
            if read == 3 {
                block(.mutationDeniedGenerationRecheck)
            }
            return .permissionDenied
        }
        return ApplicationService(
            applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
            applicationMutationCandidateProvider: { identifier in
                #expect(identifier == pid)
                #expect(generationReads.value == 1)
                selectorReads.withValue { $0 += 1 }
                block(.mutationSelector)
                return ApplicationIdentifierMatcher.Candidate(
                    processIdentifier: pid,
                    bundleIdentifier: nil,
                    name: "Late Mutation App",
                    isRegularApplication: true)
            },
            frontmostProcessIdentifierProvider: { nil },
            processStartIdentityProvider: { identifier in
                #expect(identifier == pid)
                let read = generationReads.withValue { $0 += 1; return $0 }
                if read == 2 {
                    if phase == .listingFinalGeneration {
                        #expect(metadataReads.value == 1)
                        #expect(selectorReads.value == 0)
                        block(.listingFinalGeneration)
                    } else if phase == .mutationFinalGeneration {
                        #expect(selectorReads.value == 1)
                        #expect(metadataReads.value == 0)
                        block(.mutationFinalGeneration)
                    }
                }
                return 7
            },
            mutationIdentityObservationProvider: phase.readsDeniedGeneration ? deniedIdentityProvider : nil,
            mutationEligibilityProvider: { identifier in
                #expect(identifier == pid)
                let read = eligibilityReads.withValue { $0 += 1; return $0 }
                block(read == 1 ? .mutationEligibility : .mutationEligibilityRecheck)
                return Self.eligibility(pid: pid)
            },
            runningApplicationProcessIdentifiersProvider: {
                block(.listingPID)
                block(.mutationPID)
                return [pid]
            },
            applicationWindowCatalogProvider: {
                #expect(generationReads.value == 0)
                block(.listingCatalog)
                return []
            },
            applicationMetadataProvider: { identifier, generation, _ in
                #expect(identifier == pid)
                #expect(generation == 7)
                #expect(generationReads.value == 1)
                metadataReads.withValue { $0 += 1 }
                return Self.metadata(name: "Late Listing App")
            },
            applicationInventoryOverallTimeout: cancel ? 30 : 0.05)
    }

    private static func metadata(name: String) -> DetachedApplicationMetadata {
        DetachedApplicationMetadata(
            bundleIdentifier: "com.example.fixture",
            name: name,
            bundlePath: nil,
            isHidden: false,
            activationPolicy: .regular,
            isFinishedLaunching: true)
    }

    private static func window(id: Int, pid: pid_t, appName: String) -> WindowIdentityInfo {
        WindowIdentityInfo(
            windowID: CGWindowID(id),
            title: appName,
            bounds: CGRect(x: 10, y: 20, width: 800, height: 600),
            ownerPID: pid,
            applicationName: appName,
            bundleIdentifier: nil,
            layer: 0,
            alpha: 1,
            axIdentifier: nil)
    }
}

extension ApplicationInventoryTimeoutTests {
    @Test(arguments: [uid_t(501), uid_t(0)])
    @MainActor
    func `denied foreign prohibited rows do not poison readable targets or disappear from listing`(
        hostUserID: uid_t) async throws
    {
        let applications = [
            Self.mutationApplication(pid: 41001, name: "Editor", policy: .regular),
            Self.mutationApplication(pid: 41002, name: "Denied Helper", generation: nil),
            Self.mutationApplication(pid: 41003, name: "Other Denied Helper", generation: nil),
            Self.mutationApplication(pid: 41004, name: "Own Helper"),
            Self.mutationApplication(pid: 41005, name: "Privileged Readable Foreign Helper"),
        ]
        let generations = Dictionary(uniqueKeysWithValues: applications.map {
            ($0.processIdentifier, $0.processStartIdentity)
        })
        let identityReads = AutomationTestLockedValue<[pid_t: Int]>([:])
        let eligibilityReads = AutomationTestLockedValue<[pid_t: Int]>([:])
        let service = Self.mutationService(
            applications: applications,
            identityProvider: { pid in
                identityReads.withValue { $0[pid, default: 0] += 1 }
                return generations[pid].flatMap(\.self)
                    .map(SystemIdentityResolver.ProcessStartIdentityObservation.identity)
                    ?? .permissionDenied
            },
            eligibilityProvider: { pid in
                eligibilityReads.withValue { $0[pid, default: 0] += 1 }
                return Self.eligibility(pid: pid, userID: pid == 41004 ? hostUserID : 502, hostUserID: hostUserID)
            })
        let inventory = try await service.applicationMutationInventory()
        #expect(inventory.isComplete)
        #expect(inventory.warnings.isEmpty)
        #expect(inventory.items.map(\.processIdentifier) == [41001, 41004, 41005])
        #expect(identityReads.value == [41001: 2, 41002: 3, 41003: 3, 41004: 2, 41005: 2])
        #expect(eligibilityReads.value == [41002: 2, 41003: 2])

        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { try await service.applicationMutationInventory() })
        for application in inventory.items {
            for identifier in try [application.name, #require(application.bundleIdentifier)] {
                let plan = try await planner.plan(identifier: identifier)
                #expect(plan.processIdentity == application.processIdentity)
            }
        }
        // The shared PID provider and read-only inventory still include the denied helpers.
        let listed = try await service.listApplications()
        #expect(Set(listed.data.applications.map(\.processIdentifier)) == Set(applications.map(\.processIdentifier)))
    }

    @Test(arguments: [false, true])
    @MainActor
    func `readable prohibited helpers still make duplicate name or bundle selectors ambiguous`(
        sameBundle: Bool) async throws
    {
        let target = Self.mutationApplication(pid: 41101, name: "Editor", policy: .regular)
        let helper = ServiceApplicationInfo(
            processIdentifier: 41102,
            processStartIdentity: 92,
            bundleIdentifier: sameBundle ? target.bundleIdentifier : "com.example.helper",
            name: sameBundle ? "Helper" : target.name,
            activationPolicy: .prohibited)
        let service = Self.mutationService(
            applications: [target, helper],
            identityProvider: { .identity(UInt64($0)) },
            eligibilityProvider: { _ in
                Issue.record("Readable generations must not be filtered by policy or UID")
                return nil
            })
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { try await service.applicationMutationInventory() })
        let identifier = sameBundle ? try #require(target.bundleIdentifier) : target.name
        await #expect(throws: DesktopTargetPlanningError.ambiguousApplication(
            identifier: identifier, candidatePIDs: [41101, 41102]))
        {
            _ = try await planner.plan(identifier: identifier)
        }
    }

    enum MutationEligibilityFailure: CaseIterable, Sendable {
        case ownUser, regular, accessory, unknownPolicy, missingEligibility, wrongPID
        case changedUID, changedHostUID, changedPID, changedPolicy, disappearedEligibility
        case unavailable, zeroGeneration, becameReadable, denialDisappeared, lateReadable, lateUnavailable
        case readableThenDenied, readableThenUnavailable, generationDrift
    }

    @Test(arguments: MutationEligibilityFailure.allCases)
    @MainActor
    func `uncertain denied rows and changing generations preserve fail closed name uniqueness`(
        failure: MutationEligibilityFailure) async throws
    {
        let target = Self.mutationApplication(pid: 41201, name: "Editor", policy: .regular)
        let helper = Self.mutationApplication(pid: 41202, name: "Helper")
        let identities = Self.identityObservations(for: failure)
        let evidence = Self.eligibilityObservations(for: failure, pid: helper.processIdentifier)
        let identityReads = AutomationTestLockedValue(0)
        let eligibilityReads = AutomationTestLockedValue(0)
        let service = Self.mutationService(
            applications: [target, helper],
            identityProvider: { pid in
                guard pid == helper.processIdentifier else { return .identity(90) }
                return identityReads.withValue { readIndex in
                    defer { readIndex += 1 }
                    return identities[min(readIndex, identities.count - 1)]
                }
            },
            eligibilityProvider: { pid in
                #expect(pid == helper.processIdentifier)
                return eligibilityReads.withValue { readIndex in
                    defer { readIndex += 1 }
                    return evidence[min(readIndex, evidence.count - 1)]
                }
            })
        let inventory = try await service.applicationMutationInventory()
        #expect(!inventory.isComplete)
        #expect(inventory.items.map(\.processIdentifier) == [target.processIdentifier])
        #expect(inventory.warnings.count == 1)
        #expect(identityReads.value <= 3)
        #expect(eligibilityReads.value <= 2)
        if case .identity = identities[0] {
            #expect(eligibilityReads.value == 0)
        }
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { try await service.applicationMutationInventory() })
        for identifier in try [target.name, #require(target.bundleIdentifier)] {
            identityReads.value = 0
            eligibilityReads.value = 0
            await #expect(throws: DesktopTargetPlanningError.incompleteApplicationInventory(
                identifier: identifier, warnings: inventory.warnings))
            {
                _ = try await planner.plan(identifier: identifier)
            }
        }
    }

    @Test
    @MainActor
    func `legacy optional identity injection never probes eligibility or upgrades nil to denial`() async throws {
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
            applicationMutationCandidateProvider: { _ in
                Issue.record("Missing legacy generation must not read selector metadata")
                return nil
            },
            processStartIdentityProvider: { _ in nil },
            mutationEligibilityProvider: { _ in
                Issue.record("Missing legacy generation must not read native eligibility")
                return nil
            },
            runningApplicationProcessIdentifiersProvider: { [41301] })
        let inventory = try await service.applicationMutationInventory()
        #expect(!inventory.isComplete)
        #expect(inventory.warnings == [
            "Application PID 41301 lacked process-generation identity and was omitted.",
        ])
    }

    private static func eligibility(
        pid: pid_t,
        userID: uid_t = 502,
        hostUserID: uid_t = 501,
        policy: ServiceApplicationActivationPolicy = .prohibited) -> ApplicationMutationEligibility
    {
        ApplicationMutationEligibility(
            credentials: .init(processIdentifier: pid, effectiveUserID: userID),
            runtimeHostUserID: hostUserID,
            activationPolicy: policy)
    }

    private static func identityObservations(for failure: MutationEligibilityFailure)
        -> [SystemIdentityResolver.ProcessStartIdentityObservation]
    {
        let denied = SystemIdentityResolver.ProcessStartIdentityObservation.permissionDenied
        return switch failure {
        case .unavailable: [.unavailable]
        case .zeroGeneration: [.identity(0)]
        case .becameReadable: [denied, .identity(90)]
        case .denialDisappeared: [denied, .unavailable]
        case .lateReadable: [denied, denied, .identity(90)]
        case .lateUnavailable: [denied, denied, .unavailable]
        case .readableThenDenied: [.identity(90), denied]
        case .readableThenUnavailable: [.identity(90), .unavailable]
        case .generationDrift: [.identity(90), .identity(91)]
        default: [denied]
        }
    }

    private static func eligibilityObservations(for failure: MutationEligibilityFailure, pid: pid_t)
        -> [ApplicationMutationEligibility?]
    {
        let stable = Self.eligibility(pid: pid)
        return switch failure {
        case .ownUser: [Self.eligibility(pid: pid, userID: 501)]
        case .regular: [Self.eligibility(pid: pid, policy: .regular)]
        case .accessory: [Self.eligibility(pid: pid, policy: .accessory)]
        case .unknownPolicy: [Self.eligibility(pid: pid, policy: .unknown)]
        case .missingEligibility: [nil]
        case .wrongPID: [Self.eligibility(pid: 99999)]
        case .changedUID: [stable, Self.eligibility(pid: pid, userID: 503)]
        case .changedHostUID: [stable, Self.eligibility(pid: pid, hostUserID: 0)]
        case .changedPID: [stable, Self.eligibility(pid: 99999)]
        case .changedPolicy: [stable, Self.eligibility(pid: pid, policy: .accessory)]
        case .disappearedEligibility: [stable, nil]
        default: [stable]
        }
    }

    private static func mutationApplication(
        pid: pid_t,
        name: String,
        generation: UInt64? = 90,
        policy: ServiceApplicationActivationPolicy = .prohibited) -> ServiceApplicationInfo
    {
        ServiceApplicationInfo(
            processIdentifier: pid,
            processStartIdentity: generation,
            bundleIdentifier: "com.example.\(pid)",
            name: name,
            activationPolicy: policy)
    }

    @MainActor
    private static func mutationService(
        applications: [ServiceApplicationInfo],
        identityProvider: @escaping ApplicationService.MutationIdentityObservationProvider,
        eligibilityProvider: @escaping ApplicationService.MutationEligibilityProvider) -> ApplicationService
    {
        let byPID = Dictionary(uniqueKeysWithValues: applications.map { ($0.processIdentifier, $0) })
        return ApplicationService(
            applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
            applicationMutationCandidateProvider: { byPID[$0].map(ApplicationIdentifierMatcher.Candidate.init) },
            frontmostProcessIdentifierProvider: { nil },
            processStartIdentityProvider: { identityProvider($0).identity },
            mutationIdentityObservationProvider: identityProvider,
            mutationEligibilityProvider: eligibilityProvider,
            runningApplicationProcessIdentifiersProvider: { applications.map(\.processIdentifier) },
            applicationWindowCatalogProvider: { [] },
            applicationMetadataProvider: { pid, _, _ in
                let application = try #require(byPID[pid])
                return try DetachedApplicationMetadata(
                    bundleIdentifier: application.bundleIdentifier,
                    name: application.name,
                    bundlePath: nil,
                    isHidden: false,
                    activationPolicy: #require(application.activationPolicy),
                    isFinishedLaunching: true)
            })
    }
}

private enum ApplicationInventoryFixtureError: Error {
    case unused
}

private actor ApplicationInventoryGate {
    private var started = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        self.started = true
        let waiters = self.continuations
        self.continuations.removeAll()
        for continuation in waiters {
            continuation.resume()
        }
    }

    func wait() async {
        guard !self.started else { return }
        await withCheckedContinuation { continuation in
            self.continuations.append(continuation)
        }
    }
}

private final class ApplicationInventoryBlockingGate: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let releaseGate = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let released = AutomationTestLockedValue(false)

    var wasReleased: Bool {
        self.released.value
    }

    func startedAsynchronously() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: self.waitUntilStarted()) }
        }
    }

    func waitWithEmergencyRelease() {
        _ = self.releaseGate.wait(timeout: .now() + 3)
        self.released.value = true
    }

    func markStarted() {
        self.started.signal()
    }

    func waitUntilStarted() -> Bool {
        self.started.wait(timeout: .now() + 1) == .success
    }

    func wait() {
        self.releaseGate.wait()
    }

    func release() {
        self.released.value = true
        self.releaseGate.signal()
    }

    func markFinished() {
        self.finished.signal()
    }

    func waitUntilFinished() -> Bool {
        self.finished.wait(timeout: .now() + 1) == .success
    }
}

private final class ApplicationInventoryFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        self.lock.withLock { self.storage }
    }

    func set() {
        self.lock.withLock { self.storage = true }
    }
}

private actor ApplicationMetadataConcurrencyProbe {
    private var inFlight = 0
    private(set) var maximumInFlight = 0
    private(set) var totalEntered = 0
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func enterAndWait() async {
        self.inFlight += 1
        self.totalEntered += 1
        self.maximumInFlight = max(self.maximumInFlight, self.inFlight)
        let totalEntered = self.totalEntered
        let satisfied = self.enteredWaiters.filter { totalEntered >= $0.count }
        self.enteredWaiters.removeAll { totalEntered >= $0.count }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
        if !self.released {
            await withCheckedContinuation { continuation in
                self.releaseWaiters.append(continuation)
            }
        }
        self.inFlight -= 1
    }

    func waitUntilEntered(_ count: Int) async {
        guard self.totalEntered < count else { return }
        await withCheckedContinuation { continuation in
            self.enteredWaiters.append((count, continuation))
        }
    }

    func releaseAll() {
        self.released = true
        let waiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor ApplicationMetadataTimeoutRecorder {
    private(set) var timeouts: [TimeInterval] = []

    func record(processIdentifier _: pid_t, timeout: TimeInterval) {
        self.timeouts.append(timeout)
    }
}

extension Duration {
    fileprivate var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
