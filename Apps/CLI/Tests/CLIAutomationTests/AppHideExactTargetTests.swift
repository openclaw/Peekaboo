import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@MainActor
@Suite(.serialized, .tags(.safe))
struct AppHideExactTargetTests {
    @Test
    func `app hide dispatches exact PID and publishes process target identity`() async throws {
        let processStartIdentity: UInt64 = 9_007_199_254_740_993
        let application = ServiceApplicationInfo(
            processIdentifier: 4070,
            processStartIdentity: processStartIdentity,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture"
        )
        let service = ExactHideApplicationService(applications: [application])
        let services = TestServicesFactory.makePeekabooServices(applications: service)

        let result = try await InProcessCommandRunner.run(
            ["app", "hide", "--app", "Fixture", "--json", "--no-remote"],
            services: services
        )

        let object = try Self.jsonObject(result.stdout)
        let data = try #require(object["data"] as? [String: Any])
        let target = try #require(object["target_identity"] as? [String: Any])
        let targetReceipt = try #require(object["target_receipt"] as? [String: Any])
        let outcome = try #require(object["outcome"] as? [String: Any])
        #expect(result.exitStatus == 0)
        #expect(try service.targetedHideRequests == [ApplicationHideRequest(
            identifier: "PID:4070",
            expectedIdentity: .init(processIdentifier: 4070, processStartIdentity: processStartIdentity)
        )])
        #expect(data["pid"] as? Int == 4070)
        #expect(data["process_start_identity_decimal"] as? String == String(processStartIdentity))
        #expect(target["kind"] as? String == "process")
        #expect(target["pid"] as? Int == 4070)
        #expect(target["process_start_identity_decimal"] as? String == String(processStartIdentity))
        #expect(targetReceipt["pid"] as? Int == 4070)
        #expect(targetReceipt["process_start_identity_decimal"] as? String == String(processStartIdentity))
        #expect(targetReceipt["window_id"] == nil)
        #expect(outcome["state"] as? String == "confirmed_change")
    }

    @Test
    func `app hide refuses fuzzy selector while exact name bundle and PID selectors remain valid`() async throws {
        let application = ServiceApplicationInfo(
            processIdentifier: 4070,
            processStartIdentity: 70,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture",
            isHiddenKnown: true,
            activationPolicy: .regular
        )
        let service = ExactHideApplicationService(applications: [application])
        let services = TestServicesFactory.makePeekabooServices(applications: service)

        let fuzzy = try await InProcessCommandRunner.run(
            ["app", "hide", "--app", "Fixt", "--json", "--no-remote"],
            services: services
        )
        #expect(fuzzy.exitStatus == 1)
        #expect(fuzzy.combinedOutput.contains("not allowed for mutation"))
        #expect(service.targetedHideRequests.isEmpty)

        for selector in ["Fixture", "com.example.fixture", "PID:4070"] {
            let exact = try await InProcessCommandRunner.run(
                ["app", "hide", "--app", selector, "--json", "--no-remote"],
                services: services
            )
            #expect(exact.exitStatus == 0, "Expected exact selector \(selector) to pass")
        }
        #expect(service.targetedHideRequests.count == 3)
        #expect(service.targetedHideRequests.allSatisfy { $0.identifier == "PID:4070" })
    }

    @Test
    func `frontmost mutation refusal renders direct guidance instead of an app name payload`() async throws {
        let application = ServiceApplicationInfo(
            processIdentifier: 4070,
            processStartIdentity: 70,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture",
            isHiddenKnown: true,
            activationPolicy: .regular
        )
        let service = ExactHideApplicationService(applications: [application])
        let services = TestServicesFactory.makePeekabooServices(applications: service)

        let result = try await InProcessCommandRunner.run(
            ["app", "hide", "--app", "frontmost", "--json", "--no-remote"],
            services: services
        )

        #expect(result.exitStatus == 1)
        #expect(result.combinedOutput.contains("Application 'frontmost' is not a mutation-safe target"))
        #expect(!result.combinedOutput.contains("not found"))
        #expect(service.targetedHideRequests.isEmpty)
    }

    @Test
    func `app hide rejects a mismatched returned process generation`() async throws {
        let application = ServiceApplicationInfo(
            processIdentifier: 4070,
            processStartIdentity: 70,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture"
        )
        let service = ExactHideApplicationService(applications: [application])
        service.returnedIdentity = ApplicationProcessIdentity(
            processIdentifier: 4070,
            processStartIdentity: 71
        )
        let services = TestServicesFactory.makePeekabooServices(applications: service)

        let result = try await InProcessCommandRunner.run(
            ["app", "hide", "--app", "Fixture", "--json", "--no-remote"],
            services: services
        )

        let object = try Self.jsonObject(result.stdout)
        let outcome = try #require(object["outcome"] as? [String: Any])
        #expect(result.exitStatus == 1)
        #expect(service.targetedHideRequests.map(\.identifier) == ["PID:4070"])
        #expect(service.targetedHideRequests.first?.expectedIdentity.processStartIdentity == 70)
        #expect(outcome["state"] as? String == "indeterminate")
        #expect(outcome["retry_safe"] as? Bool == false)
    }

    @Test
    func `app hide rejects a targetless result after exact dispatch`() async throws {
        let application = ServiceApplicationInfo(
            processIdentifier: 4070,
            processStartIdentity: 70,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture"
        )
        let service = ExactHideApplicationService(applications: [application])
        service.omitsReturnedTarget = true
        let services = TestServicesFactory.makePeekabooServices(applications: service)

        let result = try await InProcessCommandRunner.run(
            ["app", "hide", "--app", "Fixture", "--json", "--no-remote"],
            services: services
        )

        let object = try Self.jsonObject(result.stdout)
        let outcome = try #require(object["outcome"] as? [String: Any])
        #expect(result.exitStatus == 1)
        #expect(service.targetedHideRequests.map(\.identifier) == ["PID:4070"])
        #expect(outcome["state"] as? String == "indeterminate")
        #expect(object["target_identity"] == nil)
    }

    @Test
    func `app hide refuses legacy targetless service before mutation`() async throws {
        let application = ServiceApplicationInfo(
            processIdentifier: 4070,
            processStartIdentity: 70,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture"
        )
        let service = StubApplicationService(applications: [application])

        do {
            _ = try await ApplicationServiceBridge.hideApplication(
                applications: service,
                application: application
            )
            Issue.record("Expected targetless application service refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.outcome.dispatchState == .none)
        }

        #expect(service.hideCalls.isEmpty)
    }

    @Test
    func `app hide returned failure publishes selected process receipt`() async throws {
        let identity = ApplicationProcessIdentity(
            processIdentifier: 4070,
            processStartIdentity: 9_007_199_254_740_993
        )
        let application = ServiceApplicationInfo(
            processIdentifier: identity.processIdentifier,
            processStartIdentity: identity.processStartIdentity,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture"
        )
        let service = ExactHideApplicationService(applications: [application])
        service.outcome = .indeterminate(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one
        )
        let services = TestServicesFactory.makePeekabooServices(applications: service)

        let result = try await InProcessCommandRunner.run(
            ["app", "hide", "--app", "Fixture", "--json", "--no-remote"],
            services: services
        )

        let object = try Self.jsonObject(result.stdout)
        let target = try #require(object["target_receipt"] as? [String: Any])
        #expect(result.exitStatus == 1)
        #expect(target["pid"] as? Int == 4070)
        #expect(target["process_start_identity_decimal"] as? String == String(identity.processStartIdentity))
        #expect(target["window_id"] == nil)
    }

    @Test
    func `app hide preserves targetless pre-dispatch refusal`() async throws {
        let application = ServiceApplicationInfo(
            processIdentifier: 4070,
            processStartIdentity: 70,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture"
        )
        let service = ExactHideApplicationService(applications: [application])
        service.outcome = .refused(route: .bridge, reason: .targetUnavailable)
        service.omitsReturnedTarget = true

        do {
            _ = try await ApplicationServiceBridge.hideApplication(
                applications: service,
                application: application
            )
            Issue.record("Expected targetless refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.targetReceipt == nil)
        }
    }

    private static func jsonObject(_ output: String) throws -> [String: Any] {
        let data = try #require(output.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@MainActor
private final class ExactHideApplicationService: StubApplicationService,
ApplicationServiceTargetedActionResultProviding {
    var outcome: DesktopActionOutcome? = .confirmedChange(
        delivery: .init(mechanism: .nativeFramework, mode: .background),
        unitCount: .one
    )
    var returnedIdentity: ApplicationProcessIdentity?
    var omitsReturnedTarget = false
    var actionError: DesktopActionFailure?
    private(set) var targetedHideRequests: [ApplicationHideRequest] = []

    func activateApplicationTargetedActionResult(
        request: ApplicationActivationRequest
    ) async throws -> UIAutomationActionResult<Void> {
        guard let identity = request.expectedIdentity else {
            throw PeekabooError.serviceUnavailable("Missing activation process identity")
        }
        return try UIAutomationActionResult(
            payload: (),
            outcome: .confirmedNoChange(),
            targetIdentity: DesktopTargetIdentity(processIdentity: identity)
        )
    }

    func hideApplicationTargetedActionResult(identifier: String) async throws -> UIAutomationActionResult<Void> {
        throw PeekabooError.notImplemented("Unpinned targeted hide \(identifier)")
    }

    func hideApplicationTargetedActionResult(
        request: ApplicationHideRequest
    ) async throws -> UIAutomationActionResult<Void> {
        self.targetedHideRequests.append(request)
        if let actionError {
            throw actionError
        }
        guard let application = self.applications.first(where: {
            request.identifier == "PID:\($0.processIdentifier)"
        }), application.processIdentity == request.expectedIdentity
        else {
            throw PeekabooError.appNotFound(request.identifier)
        }
        let identity = self.returnedIdentity ?? request.expectedIdentity
        return try UIAutomationActionResult(
            payload: (),
            outcome: self.outcome,
            targetIdentity: self.omitsReturnedTarget ? nil : DesktopTargetIdentity(processIdentity: identity)
        )
    }

    func hideOtherApplicationsActionResult(identifier _: String) async throws -> DesktopActionResult<Void> {
        DesktopActionResult(outcome: .confirmedNoChange())
    }

    func showAllApplicationsActionResult() async throws -> DesktopActionResult<Void> {
        DesktopActionResult(outcome: .confirmedNoChange())
    }
}
