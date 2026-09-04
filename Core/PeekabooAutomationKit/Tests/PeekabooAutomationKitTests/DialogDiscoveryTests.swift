import ApplicationServices
import AXorcist
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct DialogDiscoveryTests {
    @Test
    func `unreadable subrole cannot hide another alert`() async {
        let fixture = DialogDiscoveryFixture()
        fixture.classificationIsReadable = false
        await fixture.expectPreparationRefusal()
        #expect(fixture.pressCount == 0)
    }

    @Test
    func `discovered proof round trips and binds uniqueness`() async throws {
        let fixture = DialogDiscoveryFixture()
        let receipt = try await fixture.service.prepareDialogAction(fixture.request())
        let decoded = try JSONDecoder().decode(
            PreparedDialogActionReceipt.self,
            from: JSONEncoder().encode(receipt))
        #expect(decoded == receipt)
        let proof = try #require(decoded.discoveryProof)
        let ambiguous = DialogDiscoverySelectionProof(
            scannedOwners: proof.scannedOwners,
            isComplete: true,
            dialogCount: 2,
            enabledPressButtonCount: 1,
            buttonTitle: proof.buttonTitle)
        #expect(!ambiguous.validates(target: receipt.target, buttonText: "Don't Allow"))
        let incomplete = DialogDiscoverySelectionProof(
            scannedOwners: proof.scannedOwners,
            isComplete: false,
            dialogCount: 1,
            enabledPressButtonCount: 1,
            buttonTitle: proof.buttonTitle)
        #expect(!incomplete.validates(target: receipt.target, buttonText: "Don't Allow"))
    }

    @Test func `nil focused application still finds system alert`() async throws {
        let fixture = DialogDiscoveryFixture()
        let result = try await fixture.service.listDialogElements(
            windowTitle: nil,
            appName: nil)
        #expect(result.discovery?.isComplete == true)
        #expect(result.discovery?.dialogs.first?.owner.bundleIdentifier == "com.apple.UserNotificationCenter")
        #expect(result.dialogInfo.title.isEmpty)
        #expect(result.staticTexts == ["sshd-keygen-wrapper wants access to control Fixture."])
        #expect(result.buttons.first?.supportsAXPress == true)
    }

    @Test func `unrelated focused application does not hide system alert`() throws {
        let fixture = DialogDiscoveryFixture()
        fixture.applications.append(fixture.application(
            pid: 77,
            bundle: "com.example.Editor"))
        fixture.focused = [77]
        let scan = try fixture.service.discoverDialogCandidates()
        #expect(scan.candidates.count == 1)
        #expect(Set(fixture.scanned) == [42, 77])
    }

    @Test(arguments: [ServiceApplicationActivationPolicy.accessory, .prohibited])
    func `allowlisted host is scanned even when accessory or prohibited`(
        _ policy: ServiceApplicationActivationPolicy) throws
    {
        let fixture = DialogDiscoveryFixture()
        fixture.applications = [fixture.application(policy: policy)]
        #expect(try fixture.service.discoverDialogCandidates().candidates.count == 1)
    }

    @Test func `non allowlisted process is not scanned`() throws {
        let fixture = DialogDiscoveryFixture()
        fixture.applications.append(fixture.application(
            pid: 77,
            bundle: "com.example.SecurityAgent"))
        _ = try fixture.service.discoverDialogCandidates()
        #expect(fixture.scanned == [42])
        fixture.applications = [ServiceApplicationInfo(
            processIdentifier: 77,
            processStartIdentity: 9001,
            bundleIdentifier: "com.apple.SecurityAgent",
            name: "SecurityAgent",
            bundlePath: "/tmp/SecurityAgent.app",
            executablePath: "/tmp/SecurityAgent.app/Contents/MacOS/SecurityAgent")]
        #expect(try fixture.service.discoverDialogCandidates().candidates.isEmpty)
        #expect(fixture.scanned == [42])
    }

    @Test func `incomplete discovery cannot authorize automatic click`() async {
        let fixture = DialogDiscoveryFixture()
        fixture.unreadable = true
        await fixture.expectPreparationRefusal()
        #expect(fixture.pressCount == 0)
    }

    @Test func `ambiguous system alerts refuse`() async throws {
        let fixture = DialogDiscoveryFixture()
        fixture.windows[42]?.append(fixture.makeAlert(20))
        await fixture.expectPreparationRefusal()
        let result = try await fixture.service.listDialogElements(
            windowTitle: nil,
            appName: nil)
        #expect(result.discovery?.dialogs.count == 2)
        #expect(result.resolvedTarget == nil)
    }

    @Test func `alert under AX group is discovered`() async throws {
        let fixture = DialogDiscoveryFixture()
        let alert = try #require(fixture.windows[42]?.first)
        let group = fixture.element(
            30,
            role: "AXGroup",
            children: [alert])
        fixture.windows[42] = [fixture.element(
            31,
            role: "AXWindow",
            children: [group])]
        let result = try await fixture.service.listDialogElements(
            windowTitle: nil,
            appName: nil)
        #expect(result.discovery?.dialogs.count == 1)
        #expect(result.dialogInfo.subrole == "AXSystemDialog")
    }

    @Test func `dont allow matches curly apostrophe variant`() async throws {
        let fixture = DialogDiscoveryFixture()
        let receipt = try await fixture.service.prepareDialogAction(fixture.request())
        #expect(receipt.discoveryProof?.buttonTitle == "Don’t Allow")
        #expect(receipt.discoveryProof?.validates(
            target: receipt.target,
            buttonText: "Don't Allow") == true)
        #expect(receipt.discoveryProof?.validates(
            target: receipt.target,
            buttonText: "Allow") == false)
        #expect(receipt.target.identity.ownerProcessIdentifier == 42)
        #expect(receipt.target.identity.ownerProcessStartIdentity == 9001)
        #expect(receipt.target.identity.windowID == 700)
    }

    @Test func `discovered receipt verifies disappearance without foreground or pointer calls`() async throws {
        let fixture = DialogDiscoveryFixture()
        let receipt = try await fixture.service.prepareDialogAction(fixture.request())
        let result = try await fixture.service.performPreparedDialogAction(receipt)
        #expect(result.success)
        #expect(result.outcome?.state == .confirmedChange)
        #expect(fixture.pressCount == 1)
        #expect(fixture.driver.events.isEmpty)
        #expect(fixture.driver.targetedClickAttempts == 0)
        #expect(fixture.focus.focusCalls == 0)
        #expect(fixture.focus.spaceSwitchCalls == 0)
    }

    @Test(arguments: ["disabled", "duplicate", "noPress", "unreadablePress"])
    func `unsafe buttons refuse`(_ kind: String) async {
        let fixture = DialogDiscoveryFixture()
        fixture.windows[42] = [fixture.makeAlert(
            10,
            disabled: kind == "disabled",
            duplicate: kind == "duplicate")]
        fixture.pressSupport = kind == "noPress" ? false : (kind == "unreadablePress" ? nil : true)
        await fixture.expectPreparationRefusal()
        #expect(fixture.pressCount == 0)
    }

    @Test(arguments: ["bounds", "window", "generation", "button", "ambiguous", "incomplete"])
    func `changed receipt refuses before dispatch`(_ change: String) async throws {
        let fixture = DialogDiscoveryFixture()
        let receipt = try await fixture.service.prepareDialogAction(fixture.request())
        switch change {
        case "bounds": fixture.bounds.origin.x += 1
        case "window": fixture.windowID += 1
        case "generation": fixture.applications = [fixture.application(generation: 9002)]
        case "button": fixture.windows[42] = [fixture.makeAlert(90)]
        case "ambiguous": fixture.windows[42]?.append(fixture.makeAlert(90))
        default: fixture.unreadable = true
        }
        do {
            _ = try await fixture.service.performPreparedDialogAction(receipt)
            Issue.record("Expected changed receipt refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }
        #expect(fixture.pressCount == 0)
        #expect(fixture.driver.events.isEmpty)
    }

    @Test func `accepted but unverified press remains retry unsafe`() async throws {
        let fixture = DialogDiscoveryFixture()
        fixture.disappears = false
        let receipt = try await fixture.service.prepareDialogAction(fixture.request())
        do {
            _ = try await fixture.service.performPreparedDialogAction(receipt)
            Issue.record("Expected unverified postcondition")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.retrySafety == .unsafe)
        }
        #expect(fixture.pressCount == 1)
    }

    @Test func `bounded traversal refuses incomplete tree`() async {
        let fixture = DialogDiscoveryFixture()
        var child = fixture.makeAlert(80)
        for identity in 100...120 {
            child = fixture.element(
                Int32(identity),
                role: "AXGroup",
                children: [child])
        }
        fixture.windows[42] = [fixture.element(
            200,
            role: "AXWindow",
            children: [child])]
        await fixture.expectPreparationRefusal()
    }
}
