import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct ApplicationMutationPlannerTests {
    @Test
    func `malformed PID selectors refuse before direct provider lookup`() async {
        var directReadCount = 0
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { .complete([]) },
            exactIdentifierProvider: { _ in
                directReadCount += 1
                return AutomationTestFixtures.application()
            })

        for identifier in ["PID:0", "PID:-1", "PID:999999999999", "PID:not-a-number"] {
            await #expect(throws: DesktopTargetPlanningError.invalidSelector(
                .invalidApplicationProcessIdentifier))
            {
                _ = try await planner.plan(identifier: identifier)
            }
        }
        #expect(directReadCount == 0)
    }

    @Test
    func `planner refuses nonpositive process identities from inventory and direct proof`() async {
        let invalidPID = AutomationTestFixtures.application(processIdentifier: 0, processStartIdentity: 1)
        let namePlanner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { .complete([invalidPID]) })
        await #expect(throws: DesktopTargetPlanningError.invalidProcessIdentity(
            processIdentifier: 0,
            processStartIdentity: 1))
        {
            _ = try await namePlanner.plan(identifier: "Test App")
        }

        let invalidGeneration = AutomationTestFixtures.application(
            processIdentifier: 101,
            processStartIdentity: 0)
        let pidPlanner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { .complete([]) },
            exactIdentifierProvider: { _ in invalidGeneration })
        await #expect(throws: DesktopTargetPlanningError.invalidProcessIdentity(
            processIdentifier: 101,
            processStartIdentity: 0))
        {
            _ = try await pidPlanner.plan(identifier: "PID:101")
        }
    }

    @Test
    func `partial inventory never proves unique name or bundle selection`() async {
        let application = AutomationTestFixtures.application()
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: {
                .partial([application], warnings: ["one application timed out"])
            })

        await #expect(throws: DesktopTargetPlanningError.incompleteApplicationInventory(
            identifier: "Test App",
            warnings: ["one application timed out"]))
        {
            _ = try await planner.plan(identifier: "Test App")
        }
    }

    @Test
    func `exact PID uses direct proof when broad inventory is partial`() async throws {
        let application = AutomationTestFixtures.application()
        var broadReadCount = 0
        var directReadCount = 0
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: {
                broadReadCount += 1
                return .partial([], warnings: ["catalog incomplete"])
            },
            exactIdentifierProvider: { _ in
                directReadCount += 1
                return application
            })

        let plan = try await planner.plan(identifier: "PID:101")

        #expect(plan.processIdentity == application.processIdentity)
        #expect(try plan.expectedTargetIdentity.processIdentity == application.processIdentity)
        #expect(try plan.expectedTargetIdentity.exactWindow == nil)
        #expect(broadReadCount == 0)
        #expect(directReadCount == 2)
    }

    @Test
    func `exact provider transport failures stay unavailable instead of impersonating target loss`() async throws {
        let application = AutomationTestFixtures.application()
        let shouldFail = AutomationTestLockedValue(true)
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { .complete([]) },
            exactIdentifierProvider: { _ in
                if shouldFail.value {
                    throw PeekabooError.commandFailed("raw provider failure")
                }
                return application
            })

        await #expect(throws: DesktopTargetPlanningError.applicationInventoryUnavailable(
            identifier: "PID:101"))
        {
            _ = try await planner.plan(identifier: "PID:101")
        }

        shouldFail.value = false
        let plan = try await planner.plan(identifier: "PID:101")
        shouldFail.value = true
        await #expect(throws: DesktopTargetPlanningError.applicationInventoryUnavailable(identifier: "PID:101")) {
            _ = try await planner.revalidate(plan)
        }
    }

    @Test
    func `exact provider absence becomes not found initially and stale after selection`() async throws {
        let application = AutomationTestFixtures.application()
        let isMissing = AutomationTestLockedValue(true)
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { .complete([]) },
            exactIdentifierProvider: { identifier in
                guard !isMissing.value else { throw PeekabooError.appNotFound(identifier) }
                return application
            })

        await #expect(throws: DesktopTargetPlanningError.applicationNotFound(
            identifier: "PID:101",
            candidatePIDs: []))
        {
            _ = try await planner.plan(identifier: "PID:101")
        }

        isMissing.value = false
        let plan = try await planner.plan(identifier: "PID:101")
        isMissing.value = true
        await #expect(throws: DesktopTargetPlanningError.staleApplication(expected: plan.processIdentity)) {
            _ = try await planner.revalidate(plan)
        }
    }

    @Test
    func `raw broad inventory errors become canonical unavailable errors`() async {
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { throw PeekabooError.timeout("raw inventory timeout") })

        await #expect(throws: DesktopTargetPlanningError.applicationInventoryUnavailable(
            identifier: "Test App"))
        {
            _ = try await planner.plan(identifier: "Test App")
        }
    }

    @Test
    func `planner returns exact canonical PID and revalidates generation`() async throws {
        let application = AutomationTestFixtures.application()
        let spy = ApplicationPlannerInventorySpy(inventories: [[application], [application]])
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { try .complete(spy.next()) })

        let plan = try await planner.plan(identifier: "Test App")

        #expect(plan.application == application)
        #expect(plan.target == "PID:101")
        #expect(plan.processIdentity == application.processIdentity)
        #expect(try plan.expectedTargetIdentity == DesktopTargetIdentity(processIdentity: plan.processIdentity))
        #expect(plan.selectorProof.scope == .application)
        #expect(plan.selectorProof.normalizedSelector == "Test App")
        #expect(plan.selectorProof.matchKind == .exactName)
        #expect(plan.selectorProof.selectedProcessIdentity == application.processIdentity)
        #expect(!plan.selectorProof.hasWinningTie)
        #expect(spy.readCount == 2)
    }

    @Test
    func `planner refuses process-generation drift before returning`() async throws {
        let original = AutomationTestFixtures.application()
        let changed = AutomationTestFixtures.wrongGenerationApplication()
        let spy = ApplicationPlannerInventorySpy(inventories: [[original], [changed]])
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { try .complete(spy.next()) })
        let identity = try #require(original.processIdentity)

        await #expect(throws: DesktopTargetPlanningError.staleApplication(expected: identity)) {
            _ = try await planner.plan(identifier: "Test App")
        }
    }

    @Test
    func `empty exact revalidation becomes stale after a successful selection`() async throws {
        let application = AutomationTestFixtures.application()
        let spy = ApplicationPlannerInventorySpy(inventories: [[application], [application], []])
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { try .complete(spy.next()) })
        let plan = try await planner.plan(identifier: "Test App")

        await #expect(throws: DesktopTargetPlanningError.staleApplication(expected: plan.processIdentity)) {
            _ = try await planner.revalidate(plan)
        }
    }

    @Test
    func `exact revalidation rejects selector metadata rebound onto the same PID generation`() async throws {
        let selected = AutomationTestFixtures.application(name: "Selected App")
        let rebound = AutomationTestFixtures.application(
            bundleIdentifier: "com.example.Rebound",
            name: "Rebound App")
        let current = AutomationTestLockedValue(selected)
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { .complete([selected]) },
            exactIdentifierProvider: { _ in current.value })

        let plan = try await planner.plan(identifier: "Selected App")
        current.value = rebound

        await #expect(throws: DesktopTargetPlanningError.staleApplication(expected: plan.processIdentity)) {
            _ = try await planner.revalidate(plan)
        }
    }

    @Test
    func `remote inventory without executable data never delegates to legacy lookup`() async {
        let application = AutomationTestFixtures.application(name: "OpenClaw Desktop Test")
        let spy = ApplicationPlannerInventorySpy(inventories: [[application]])
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { try .complete(spy.next()) })

        await #expect(throws: DesktopTargetPlanningError.applicationNotFound(
            identifier: "openclaw-desktop",
            candidatePIDs: []))
        {
            _ = try await planner.plan(identifier: "openclaw-desktop")
        }
        #expect(spy.readCount == 1)
    }
}

@MainActor
private final class ApplicationPlannerInventorySpy {
    private var inventories: [[ServiceApplicationInfo]]
    private(set) var readCount = 0

    init(inventories: [[ServiceApplicationInfo]]) {
        self.inventories = inventories
    }

    func next() throws -> [ServiceApplicationInfo] {
        guard self.readCount < self.inventories.count else {
            throw PeekabooError.commandFailed("Unexpected application inventory read")
        }
        defer { self.readCount += 1 }
        return self.inventories[self.readCount]
    }
}

extension ApplicationMutationPlannerTests {
    @Test(arguments: ["Messages", "mEsSaGeS", "com.apple.MobileSMS"])
    func `partial generation inventory accepts authoritative exact name and bundle proof`(
        identifier: String) async throws
    {
        let application = Self.messages()
        let census = [application, Self.omittedApplication()]
        var requests: [String] = []
        var inventoryReads = 0
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: {
                inventoryReads += 1
                return .partial([application], warnings: [Self.omissionWarning])
            },
            exactIdentifierProvider: { identifier in
                requests.append(identifier)
                return try Self.authoritativeApplication(identifier: identifier, census: census)
            })

        let plan = try await planner.plan(identifier: identifier)
        let proof = try #require(try Self.authoritativeApplication(
            identifier: identifier, census: census).selectorResolutionProofs?.first)

        #expect(plan.processIdentity == application.processIdentity)
        #expect(plan.selectorProof == proof)
        #expect(plan.selectorProof.candidateCount == 2)
        #expect(inventoryReads == 1)
        #expect(requests == [identifier, "PID:2468"])
    }

    @Test(arguments: ["Messages", "com.apple.MobileSMS"])
    func `omitted matching process still prevents authoritative selection`(identifier: String) async {
        let application = Self.messages()
        let duplicate = Self.omittedApplication(name: application.name, bundle: application.bundleIdentifier)
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { .partial([application], warnings: [Self.omissionWarning]) },
            exactIdentifierProvider: { identifier in
                try Self.authoritativeApplication(identifier: identifier, census: [application, duplicate])
            })

        await #expect(throws: DesktopTargetPlanningError.ambiguousApplication(
            identifier: identifier, candidatePIDs: []))
        {
            _ = try await planner.plan(identifier: identifier)
        }
    }

    @Test(arguments: ["missing", "selector", "generation", "tie"])
    func `partial inventory without authoritative selector proof remains refused`(invalidProof: String) async throws {
        let application = Self.messages()
        let proofApplication = invalidProof == "generation" ? Self.messages(generation: 8) : application
        let duplicate = Self.omittedApplication(name: application.name, bundle: application.bundleIdentifier)
        let census = invalidProof == "tie" ? [proofApplication, duplicate] : [proofApplication]
        let resolution = try #require(try ApplicationIdentifierMatcher.resolution(
            for: invalidProof == "selector" ? "com.apple.MobileSMS" : "Messages",
            in: census.map(ApplicationIdentifierMatcher.Candidate.init)))
        let proofs = try invalidProof == "missing" ? [] : [resolution.proof(
            selectedProcessIdentity: #require(proofApplication.processIdentity))]
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { .partial([application], warnings: [Self.omissionWarning]) },
            exactIdentifierProvider: { _ in application.withSelectorResolutionProofs(proofs) })

        await #expect(throws: DesktopTargetPlanningError.applicationInventoryUnavailable(identifier: "Messages")) {
            _ = try await planner.plan(identifier: "Messages")
        }
    }

    @Test(arguments: ["expected", "missing", "zero", "reuse", "metadata"])
    func `authoritative fallback preserves expected generation and revalidation`(failure: String) async throws {
        let original = Self.messages()
        let selected = switch failure {
        case "missing": Self.messages(generation: nil)
        case "zero": Self.messages(generation: 0)
        default: original
        }
        let current = switch failure {
        case "reuse": Self.messages(generation: 8)
        case "metadata": AutomationTestFixtures.application(
                processIdentifier: 2468, processStartIdentity: 7, name: "Rebound")
        default: selected
        }
        var requests: [String] = []
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { .partial([original], warnings: [Self.omissionWarning]) },
            exactIdentifierProvider: { identifier in
                requests.append(identifier)
                return try Self.authoritativeApplication(
                    identifier: identifier,
                    census: [identifier == "PID:2468" ? current : selected, Self.omittedApplication()])
            })
        let expected = try #require((failure == "expected" ? Self.messages(generation: 8) : original).processIdentity)
        let error: DesktopTargetPlanningError = switch failure {
        case "missing": .missingProcessIdentity(processIdentifier: 2468)
        case "zero": .invalidProcessIdentity(processIdentifier: 2468, processStartIdentity: 0)
        default: .staleApplication(expected: expected)
        }

        await #expect(throws: error) {
            _ = try await planner.plan(identifier: "Messages", expectedIdentity: expected)
        }
        #expect(requests == (["reuse", "metadata"].contains(failure) ? ["Messages", "PID:2468"] : ["Messages"]))
    }

    @Test
    func `authoritative fallback defers revalidation only when requested`() async throws {
        let application = Self.messages()
        var requests: [String] = []
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { .partial([application], warnings: [Self.omissionWarning]) },
            exactIdentifierProvider: { identifier in
                requests.append(identifier)
                return try Self.authoritativeApplication(
                    identifier: identifier, census: [application, Self.omittedApplication()])
            })
        let plan = try await planner.resolve(
            selector: InteractionTargetSelector(applicationIdentifier: "Messages"),
            expectedIdentity: application.processIdentity,
            revalidateBeforeReturn: false)
        #expect(requests == ["Messages"])
        _ = try await planner.revalidate(plan)
        #expect(requests == ["Messages", "PID:2468"])
    }

    @Test(arguments: ["Mess", "MessagesExecutable"])
    func `authoritative fallback refuses fuzzy and executable matches`(identifier: String) async {
        let application = ServiceApplicationInfo(
            processIdentifier: 2468,
            processStartIdentity: 7,
            bundleIdentifier: "com.apple.MobileSMS",
            name: "Messages",
            executablePath: "/Applications/Messages.app/Contents/MacOS/MessagesExecutable")
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { .partial([application], warnings: [Self.omissionWarning]) },
            exactIdentifierProvider: { identifier in
                try Self.authoritativeApplication(identifier: identifier, census: [application])
            })
        await #expect(throws: DesktopTargetPlanningError.unsupportedApplicationIdentifier(
            identifier: identifier, candidatePIDs: [2468]))
        {
            _ = try await planner.plan(identifier: identifier)
        }
    }

    @Test(arguments: [false, true])
    func `inventory failure never invokes authoritative fallback`(cancelled: Bool) async {
        var directReads = 0
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: {
                if cancelled {
                    throw CancellationError()
                }
                throw PeekabooError.timeout("inventory timeout")
            },
            exactIdentifierProvider: { _ in
                directReads += 1
                return Self.messages()
            })
        if cancelled {
            await #expect(throws: CancellationError.self) { _ = try await planner.plan(identifier: "Messages") }
        } else {
            await #expect(throws: DesktopTargetPlanningError.applicationInventoryUnavailable(identifier: "Messages")) {
                _ = try await planner.plan(identifier: "Messages")
            }
        }
        #expect(directReads == 0)
    }

    private static let omissionWarning =
        "Application PID 358 (AppSSODaemon, com.apple.AppSSODaemon) lacked process-generation identity and was omitted."

    private static func messages(generation: UInt64? = 7) -> ServiceApplicationInfo {
        AutomationTestFixtures.application(
            processIdentifier: 2468,
            processStartIdentity: generation,
            bundleIdentifier: "com.apple.MobileSMS",
            name: "Messages")
    }

    private static func omittedApplication(
        name: String = "AppSSODaemon", bundle: String? = "com.apple.AppSSODaemon") -> ServiceApplicationInfo
    {
        AutomationTestFixtures.application(
            processIdentifier: 358,
            processStartIdentity: nil,
            bundleIdentifier: bundle,
            name: name,
            activationPolicy: .prohibited)
    }

    private static func authoritativeApplication(
        identifier: String, census: [ServiceApplicationInfo]) throws -> ServiceApplicationInfo
    {
        guard let resolution = try ApplicationIdentifierMatcher.resolution(
            for: identifier, in: census.map(ApplicationIdentifierMatcher.Candidate.init))
        else { throw PeekabooError.appNotFound(identifier) }
        guard !resolution.hasWinningTie else {
            throw PeekabooError.ambiguousAppIdentifier(identifier, suggestions: census.map(\.name))
        }
        let application = census[resolution.index]
        guard let identity = application.processIdentity else { return application }
        return application.withSelectorResolutionProofs([resolution.proof(selectedProcessIdentity: identity)])
    }
}
