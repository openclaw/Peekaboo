import CoreGraphics
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

extension PeekabooBridgeClient {
    public func listMenus(appIdentifier: String) async throws -> MenuStructure {
        let response = try await self.send(.listMenus(PeekabooBridgeMenuListRequest(appIdentifier: appIdentifier)))
        switch response {
        case let .menuStructure(structure): return structure
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected menu list response")
        }
    }

    public func listFrontmostMenus() async throws -> MenuStructure {
        let response = try await self.send(.listFrontmostMenus)
        switch response {
        case let .menuStructure(structure): return structure
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected menu list response")
        }
    }

    public func clickMenuItem(appIdentifier: String, itemPath: String) async throws {
        try await self.sendExpectOK(.clickMenuItem(PeekabooBridgeMenuClickRequest(
            appIdentifier: appIdentifier,
            itemPath: itemPath)))
    }

    public func clickMenuItemByName(appIdentifier: String, itemName: String) async throws {
        try await self.sendExpectOK(.clickMenuItemByName(PeekabooBridgeMenuClickByNameRequest(
            appIdentifier: appIdentifier,
            itemName: itemName)))
    }

    public func listMenuExtras() async throws -> [MenuExtraInfo] {
        let response = try await self.send(.listMenuExtras)
        switch response {
        case let .menuExtras(extras): return extras
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected menu extras response")
        }
    }

    public func clickMenuExtra(title: String) async throws {
        try await self.sendExpectOK(.clickMenuExtra(PeekabooBridgeMenuBarClickByNameRequest(name: title)))
    }

    public func menuExtraOpenMenuFrame(title: String, ownerPID: pid_t?) async throws -> CGRect? {
        let response = try await self.send(.menuExtraOpenMenuFrame(
            PeekabooBridgeMenuExtraOpenRequest(title: title, ownerPID: ownerPID)))
        switch response {
        case let .rect(rect): return rect
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected menu frame response")
        }
    }

    public func listMenuBarItems(includeRaw: Bool) async throws -> [MenuBarItemInfo] {
        let response = try await self.send(.listMenuBarItems(includeRaw))
        switch response {
        case let .menuBarItems(items): return items
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected menu bar response")
        }
    }

    public func clickMenuBarItem(named name: String) async throws -> ClickResult {
        let response = try await self.send(.clickMenuBarItemNamed(PeekabooBridgeMenuBarClickByNameRequest(name: name)))
        switch response {
        case let .clickResult(result): return result
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected menu bar click response")
        }
    }

    public func clickMenuBarItem(at index: Int) async throws -> ClickResult {
        let response = try await self
            .send(.clickMenuBarItemIndex(PeekabooBridgeMenuBarClickByIndexRequest(index: index)))
        switch response {
        case let .clickResult(result): return result
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected menu bar click response")
        }
    }

    public func listDockItems(includeAll: Bool) async throws -> [DockItem] {
        let response = try await self.send(.listDockItems(PeekabooBridgeDockListRequest(includeAll: includeAll)))
        switch response {
        case let .dockItems(items): return items
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected dock list response")
        }
    }

    public func launchDockItem(appName: String) async throws {
        try await self.sendExpectOK(.launchDockItem(PeekabooBridgeDockLaunchRequest(appName: appName)))
    }

    public func rightClickDockItem(appName: String, menuItem: String?) async throws {
        try await self.sendExpectOK(.rightClickDockItem(PeekabooBridgeDockRightClickRequest(
            appName: appName,
            menuItem: menuItem)))
    }

    public func hideDock() async throws {
        try await self.sendExpectOK(.hideDock)
    }

    public func showDock() async throws {
        try await self.sendExpectOK(.showDock)
    }

    public func isDockHidden() async throws -> Bool {
        let response = try await self.send(.isDockHidden)
        switch response {
        case let .bool(value): return value
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected dock state response")
        }
    }

    public func findDockItem(name: String) async throws -> DockItem {
        let response = try await self.send(.findDockItem(PeekabooBridgeDockFindRequest(name: name)))
        switch response {
        case let .dockItem(item):
            if let item {
                return item
            }
            throw PeekabooBridgeErrorEnvelope(code: .notFound, message: "Dock item not found")
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected dock find response")
        }
    }

    public func dialogFindActive(windowTitle: String?, appName: String?) async throws -> DialogInfo {
        let response = try await self.send(.dialogFindActive(PeekabooBridgeDialogFindRequest(
            windowTitle: windowTitle,
            appName: appName)))
        switch response {
        case let .dialogInfo(info): return info
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected dialog response")
        }
    }

    public func dialogClickButton(
        buttonText: String,
        windowTitle: String?,
        appName: String?,
        allowGlobalFallback: Bool = false) async throws -> DialogActionResult
    {
        let request = PeekabooBridgeDialogClickButtonRequest(
            buttonText: buttonText,
            windowTitle: windowTitle,
            appName: appName)
        let response = try await self.send(
            allowGlobalFallback ? .dialogClickButton(request) : .backgroundDialogClickButton(request))
        switch response {
        case let .dialogResult(result): return result
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected dialog result")
        }
    }

    public func dialogEnterText(
        text: String,
        fieldIdentifier: String?,
        clearExisting: Bool,
        windowTitle: String?,
        appName: String?) async throws -> DialogActionResult
    {
        let response = try await self.send(.dialogEnterText(PeekabooBridgeDialogEnterTextRequest(
            text: text,
            fieldIdentifier: fieldIdentifier,
            clearExisting: clearExisting,
            windowTitle: windowTitle,
            appName: appName)))
        switch response {
        case let .dialogResult(result): return result
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected dialog result")
        }
    }

    public func dialogHandleFile(
        path: String?,
        filename: String?,
        actionButton: String?,
        ensureExpanded: Bool = false,
        appName: String?) async throws -> DialogActionResult
    {
        let response = try await self.send(.dialogHandleFile(PeekabooBridgeDialogHandleFileRequest(
            path: path,
            filename: filename,
            actionButton: actionButton,
            ensureExpanded: ensureExpanded,
            appName: appName)))
        switch response {
        case let .dialogResult(result): return result
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected dialog result")
        }
    }

    public func dialogDismiss(force: Bool, windowTitle: String?, appName: String?) async throws -> DialogActionResult {
        let response = try await self.send(.dialogDismiss(PeekabooBridgeDialogDismissRequest(
            force: force,
            windowTitle: windowTitle,
            appName: appName)))
        switch response {
        case let .dialogResult(result): return result
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected dialog result")
        }
    }

    public func dialogListElements(windowTitle: String?, appName: String?) async throws -> DialogElements {
        let response = try await self.send(.dialogListElements(PeekabooBridgeDialogFindRequest(
            windowTitle: windowTitle,
            appName: appName)))
        switch response {
        case let .dialogElements(elements): return elements
        case let .error(envelope): throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected dialog elements response")
        }
    }
}
