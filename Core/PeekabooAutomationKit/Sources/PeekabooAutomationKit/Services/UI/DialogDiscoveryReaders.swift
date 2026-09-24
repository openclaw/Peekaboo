import AppKit
import ApplicationServices
import AXorcist
import Foundation
import PeekabooFoundation

/// Injection boundary for read-only Workspace/AX/CG observations and the sole AXPress leaf.
@MainActor
struct DialogDiscoveryReaders {
    typealias ElementRead = (
        elements: [Element],
        readable: Bool)

    var applications: @MainActor () -> [ServiceApplicationInfo] = {
        NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map { Self.applicationInfo($0) }
    }

    var focusedOwners: @MainActor () -> Set<Int32> = {
        let system = Element.systemWide()
        AXUIElementSetMessagingTimeout(system.underlyingElement, 0.05)
        let axOwner = system.attribute(Attribute<Element>("AXFocusedApplication"))?.pid()
        let elementOwner = system.attribute(Attribute<Element>("AXFocusedUIElement"))?.pid()
        let windowOwner = system.attribute(Attribute<Element>("AXFocusedWindow"))?.pid()
        return Set([axOwner, elementOwner, windowOwner, NSWorkspace.shared.frontmostApplication?.processIdentifier]
            .compactMap(\.self))
    }

    var currentApplication: @MainActor (Int32) -> ServiceApplicationInfo? = { pid in
        NSRunningApplication(processIdentifier: pid).map { Self.applicationInfo($0) }
    }

    var windows: @MainActor (Int32) -> ElementRead = { pid in
        let app = Element(AXUIElementCreateApplication(pid))
        AXUIElementSetMessagingTimeout(app.underlyingElement, 0.05)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app.underlyingElement, kAXWindowsAttribute as CFString, &value)
        if error == .noValue {
            return ([], true)
        }
        guard error == .success, let windows = value as? [AXUIElement] else { return ([], false) }
        return (windows.map(Element.init), true)
    }

    var children: @MainActor (Element) -> ElementRead = { DialogService.traversalChildren(of: $0) }
    var hierarchyNode: @MainActor (
        Element,
        ApplicationProcessIdentity,
        DialogOperationDeadline) async throws -> DialogHierarchyNode = {
        try await DialogHierarchyReader.read($0, owner: $1, budget: $2)
    }

    var classificationReadable: @MainActor (Element) -> Bool = { element in
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element.underlyingElement, kAXSubroleAttribute as CFString, &value)
        switch error {
        case .success: return value is String
        case .attributeUnsupported, .noValue: return true
        default: return false
        }
    }

    var ownerPID: @MainActor (Element) -> Int32? = { $0.pid() }
    var supportsPress: @MainActor (Element) -> Bool? = { element in
        var actions: CFArray?
        guard AXUIElementCopyActionNames(element.underlyingElement, &actions) == .success,
              let names = actions as? [String]
        else { return nil }
        return names.contains(AXActionNames.kAXPressAction)
    }

    var windowReceipt: @MainActor (Element, ServiceApplicationInfo, Int)
        -> ServiceWindowInfo? = { window, owner, index in
            guard let generation = owner.processStartIdentity,
                  let position = window.position(), let size = window.size(),
                  let windowID = WindowIdentityService().getWindowID(
                      from: window,
                      messagingTimeout: 0.05),
                  let identity = SystemIdentityResolver.windowMutationIdentity(
                      windowID: windowID,
                      expectedOwnerProcessIdentifier: owner.processIdentifier,
                      expectedOwnerProcessStartIdentity: generation,
                      expectedBounds: CGRect(
                          origin: position,
                          size: size),
                      isMinimized: false)
            else { return nil }
            return ServiceWindowInfo(
                windowID: Int(windowID),
                title: window.title() ?? "",
                bounds: CGRect(
                    origin: position,
                    size: size),
                index: index,
                mutationIdentity: identity)
        }

    var press: @MainActor (Element) async throws -> DesktopActionOutcome = { button in
        try await DetachedAXActionRunner.perform(
            action: AXActionNames.kAXPressAction,
            on: button.underlyingElement,
            gracePeriod: DetachedAXActionRunner.pressGracePeriod)
    }

    var windowPresence: @MainActor (WindowMutationIdentity) -> DialogService.DialogPresence = {
        DialogService.windowServerPresence($0)
    }

    var now: @MainActor () -> Date = Date.init

    private static func applicationInfo(_ app: NSRunningApplication) -> ServiceApplicationInfo {
        ServiceApplicationInfo(
            processIdentifier: app.processIdentifier,
            processStartIdentity: SystemIdentityResolver.processStartIdentity(app.processIdentifier),
            bundleIdentifier: app.bundleIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "PID:\(app.processIdentifier)",
            bundlePath: app.bundleURL?.standardizedFileURL.path,
            executablePath: app.executableURL?.standardizedFileURL.path,
            activationPolicy: app.activationPolicy == .regular ? .regular :
                (app.activationPolicy == .accessory ? .accessory : .prohibited))
    }
}
