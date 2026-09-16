import ApplicationServices
import AXorcist
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
final class DialogDiscoveryFixture {
    var applications: [ServiceApplicationInfo] = []
    var focused: Set<Int32> = []
    var windows: [Int32: [Element]] = [:]
    var scanned: [Int32] = []
    var unreadable = false
    var classificationIsReadable = true
    var pressSupport: Bool? = true
    var pressCount = 0
    var disappears = true
    var windowID = 700
    var bounds = CGRect(
        x: 10,
        y: 20,
        width: 300,
        height: 200)
    let driver = ClickRecordingSyntheticInputDriver()
    let focus = DialogDiscoveryFocusRecorder()
    lazy var service = DialogService(
        applicationService: UnusedApplicationService(),
        syntheticInputDriver: self.driver,
        operationLaneCoordinator: DesktopOperationLaneCoordinator(),
        discoveryReaders: self.readers(),
        focusService: self.focus)

    init() {
        self.applications = [self.application()]
        self.windows[42] = [self.makeAlert(10)]
    }

    func request() throws -> DialogActionPreparationRequest {
        try DialogActionPreparationRequest(
            target: DialogTargetSelector(),
            kind: .clickButton,
            buttonText: "Don't Allow")
    }

    func application(
        pid: Int32 = 42,
        generation: UInt64 = 9001,
        bundle: String = "com.apple.UserNotificationCenter",
        policy: ServiceApplicationActivationPolicy = .prohibited) -> ServiceApplicationInfo
    {
        let executable = DialogSystemAlertHosts.executables[bundle] ?? "/Applications/Editor.app/Contents/MacOS/Editor"
        return ServiceApplicationInfo(
            processIdentifier: pid,
            processStartIdentity: generation,
            bundleIdentifier: bundle,
            name: bundle == "com.apple.UserNotificationCenter" ? "UserNotificationCenter" : "Editor",
            bundlePath: URL(fileURLWithPath: executable)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path,
            executablePath: executable,
            activationPolicy: policy)
    }

    func makeAlert(
        _ identity: Int32,
        disabled: Bool = false,
        duplicate: Bool = false) -> Element
    {
        let button = self.element(
            identity + 1,
            role: "AXButton",
            title: "Don’t Allow",
            enabled: !disabled)
        let message = self.element(
            identity + 2,
            role: "AXStaticText",
            title: "sshd-keygen-wrapper wants access to control Fixture.")
        var children = [button, message]
        if duplicate {
            children.append(self.element(
                identity + 3,
                role: "AXButton",
                title: "Don't Allow"))
        }
        return self.element(
            identity,
            role: "AXWindow",
            subrole: "AXSystemDialog",
            children: children)
    }

    func element(
        _ identity: Int32,
        role: String,
        subrole: String = "",
        title: String = "",
        enabled: Bool = true,
        children: [Element] = []) -> Element
    {
        Element(
            AXUIElementCreateApplication(-identity),
            attributes: [
                "AXRole": .string(role), "AXSubrole": .string(subrole), "AXTitle": .string(title),
                "AXValue": .string(""), "AXLabel": .string(""), "AXDescription": .string(""),
                "AXRoleDescription": .string(""), "AXIdentifier": .string("fixture-\(identity)"),
                "AXEnabled": .bool(enabled), "AXDefault": .bool(false), "AXModal": .bool(true),
            ],
            children: children,
            actions: ["AXPress"])
    }

    func expectPreparationRefusal() async {
        do {
            _ = try await self.service.prepareDialogAction(self.request())
            Issue.record("Expected automatic discovery refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.hint?.contains("Candidates:") == true)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func readers() -> DialogDiscoveryReaders {
        var readers = DialogDiscoveryReaders()
        readers.applications = { self.applications }
        readers.focusedOwners = { self.focused }
        readers.currentApplication = { pid in self.applications.first { $0.processIdentifier == pid } }
        readers.windows = { pid in
            self.scanned.append(pid)
            return (self.windows[pid] ?? [], !self.unreadable)
        }
        readers.children = { ($0.children() ?? [], true) }
        readers.classificationReadable = { _ in self.classificationIsReadable }
        readers.ownerPID = { _ in 42 }
        readers.supportsPress = { _ in self.pressSupport }
        readers.windowReceipt = { _, owner, index in
            let identity = WindowMutationIdentity(
                windowID: self.windowID + index,
                ownerProcessIdentifier: owner.processIdentifier,
                ownerProcessStartIdentity: owner.processStartIdentity ?? 0,
                capturedBounds: self.bounds)
            return ServiceWindowInfo(
                windowID: self.windowID + index,
                title: "",
                bounds: self.bounds,
                index: index,
                mutationIdentity: identity)
        }
        readers.press = { _ in
            self.pressCount += 1
            if self.disappears {
                self.windows[42] = []
            }
            return .dispatchedUnverified(
                delivery: .init(
                    mechanism: .accessibilityAction,
                    mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one)
        }
        readers.windowPresence = { _ in self.windows[42]?.isEmpty == true ? .absent : .present }
        return readers
    }
}
