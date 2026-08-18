import CoreGraphics
import Foundation
import PeekabooFoundation

/// Result of a click operation
public struct ClickResult: Sendable, Codable {
    public let elementDescription: String
    public let location: CGPoint?

    public init(elementDescription: String, location: CGPoint?) {
        self.elementDescription = elementDescription
        self.location = location
    }
}

/// Protocol defining menu interaction operations
@MainActor
public protocol MenuServiceProtocol: Sendable {
    /// List all menus and items for an application
    /// - Parameter appIdentifier: Application name or bundle ID
    /// - Returns: Menu structure information
    func listMenus(for appIdentifier: String) async throws -> MenuStructure

    /// List menus for the frontmost application
    /// - Returns: Menu structure information
    func listFrontmostMenus() async throws -> MenuStructure

    /// Click a menu item
    /// - Parameters:
    ///   - appIdentifier: Application name or bundle ID
    ///   - itemPath: Menu item path (e.g., "File > New" or just "New Window")
    func clickMenuItem(app: String, itemPath: String) async throws

    /// Click a menu item by searching for it recursively in the menu hierarchy
    /// - Parameters:
    ///   - app: Application name or bundle ID
    ///   - itemName: The name of the menu item to click (searches recursively)
    func clickMenuItemByName(app: String, itemName: String) async throws

    /// Click a system menu extra (status bar item)
    /// - Parameter title: Title of the menu extra
    func clickMenuExtra(title: String) async throws

    /// Check whether a menu extra has its menu currently open (AX-based).
    /// - Parameter title: Title of the menu extra
    func isMenuExtraMenuOpen(title: String, ownerPID: pid_t?) async throws -> Bool

    /// Return the open menu frame for a menu extra, if available (AX-based).
    /// - Parameter title: Title of the menu extra
    func menuExtraOpenMenuFrame(title: String, ownerPID: pid_t?) async throws -> CGRect?

    /// List all system menu extras
    /// - Returns: Array of menu extra information
    func listMenuExtras() async throws -> [MenuExtraInfo]

    /// List all menu bar items (status items) - compatibility method
    /// - Parameter includeRaw: Include raw debug metadata (window/layer/owner) if available.
    /// - Returns: Array of menu bar item information
    func listMenuBarItems(includeRaw: Bool) async throws -> [MenuBarItemInfo]

    /// Click a menu bar item by name - compatibility method
    /// - Parameter name: Name of the menu bar item
    /// - Returns: Click result
    func clickMenuBarItem(named name: String) async throws -> ClickResult

    /// Click a menu bar item by index - compatibility method
    /// - Parameter index: Index of the menu bar item
    /// - Returns: Click result
    func clickMenuBarItem(at index: Int) async throws -> ClickResult
}

/// Additive capability for menu mutations that report both execution semantics and the resolved owner.
public protocol MenuServiceActionResultProviding: MenuServiceProtocol {
    func clickMenuItemActionResult(app: String, itemPath: String) async throws -> UIAutomationActionResult<Void>

    func clickMenuItemByNameActionResult(app: String, itemName: String) async throws
        -> UIAutomationActionResult<Void>

    func clickMenuExtraActionResult(title: String) async throws -> UIAutomationActionResult<Void>

    func clickMenuBarItemActionResult(named name: String) async throws -> UIAutomationActionResult<ClickResult>

    func clickMenuBarItemActionResult(at index: Int) async throws -> UIAutomationActionResult<ClickResult>
}

/// Capability for menu-bar item providers that resolve and generation-pin the native owner before
/// dispatching either an Accessibility action or a window-routed click.
public protocol MenuServiceGenerationPinnedMenuBarActionResultProviding: MenuServiceProtocol {
    func clickMenuBarItemGenerationPinnedActionResult(named name: String) async throws
        -> UIAutomationActionResult<ClickResult>
}

/// A menu-bar mutation bound to the exact status item returned by a prior inventory read.
public struct MenuBarItemActionRequest: Sendable, Codable, Equatable {
    public let name: String?
    public let index: Int?
    public let expectedLeafEvidence: DesktopSelectedLeafEvidence

    public init(named name: String, expectedLeafEvidence: DesktopSelectedLeafEvidence) throws {
        guard expectedLeafEvidence.kind == .menuBarItem else {
            throw PeekabooError.invalidInput("Expected leaf evidence is not a menu bar item")
        }
        self.name = name
        self.index = nil
        self.expectedLeafEvidence = expectedLeafEvidence
    }

    public init(index: Int, expectedLeafEvidence: DesktopSelectedLeafEvidence) throws {
        guard index >= 0,
              expectedLeafEvidence.kind == .menuBarItem,
              expectedLeafEvidence.selectedIndex == index
        else {
            throw PeekabooError.invalidInput("Menu bar index contradicts its selected-leaf evidence")
        }
        self.name = nil
        self.index = index
        self.expectedLeafEvidence = expectedLeafEvidence
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case index
        case expectedLeafEvidence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decodeIfPresent(String.self, forKey: .name)
        let index = try container.decodeIfPresent(Int.self, forKey: .index)
        let evidence = try container.decode(DesktopSelectedLeafEvidence.self, forKey: .expectedLeafEvidence)
        do {
            if let name, index == nil {
                try self.init(named: name, expectedLeafEvidence: evidence)
            } else if let index, name == nil {
                try self.init(index: index, expectedLeafEvidence: evidence)
            } else {
                throw PeekabooError.invalidInput("Menu bar action requires exactly one selector")
            }
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .expectedLeafEvidence,
                in: container,
                debugDescription: error.localizedDescription)
        }
    }
}

/// Additive capability for a status-item mutation pinned to prior selected-leaf evidence.
public protocol MenuServiceExactLeafActionResultProviding: MenuServiceActionResultProviding {
    func clickMenuBarItemActionResult(request: MenuBarItemActionRequest) async throws
        -> UIAutomationActionResult<ClickResult>
}

/// A menu inventory read pinned to the application process generation selected by the caller.
public struct MenuListRequest: Sendable, Codable, Equatable {
    public let appIdentifier: String
    public let expectedIdentity: ApplicationProcessIdentity

    public init(
        appIdentifier: String,
        expectedIdentity: ApplicationProcessIdentity) throws
    {
        guard appIdentifier == "PID:\(expectedIdentity.processIdentifier)" else {
            throw PeekabooError.invalidInput(
                "Exact menu list identifier must match its process-generation identity")
        }
        self.appIdentifier = appIdentifier
        self.expectedIdentity = expectedIdentity
    }

    private enum CodingKeys: String, CodingKey {
        case appIdentifier
        case expectedIdentity
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let appIdentifier = try container.decode(String.self, forKey: .appIdentifier)
        let expectedIdentity = try container.decode(ApplicationProcessIdentity.self, forKey: .expectedIdentity)
        do {
            try self.init(appIdentifier: appIdentifier, expectedIdentity: expectedIdentity)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .appIdentifier,
                in: container,
                debugDescription: "Exact menu list identifier contradicts its process identity")
        }
    }
}

/// An application-menu path mutation pinned to the process generation selected by the caller.
public struct MenuItemActionRequest: Sendable, Codable, Equatable {
    public let appIdentifier: String
    public let itemPath: String
    public let expectedIdentity: ApplicationProcessIdentity
    public let deliveryMode: DesktopActionOutcome.Delivery.Mode

    public init(
        appIdentifier: String,
        itemPath: String,
        expectedIdentity: ApplicationProcessIdentity,
        deliveryMode: DesktopActionOutcome.Delivery.Mode = .background) throws
    {
        guard appIdentifier == "PID:\(expectedIdentity.processIdentifier)" else {
            throw PeekabooError.invalidInput(
                "Exact menu item identifier must match its process-generation identity")
        }
        self.appIdentifier = appIdentifier
        self.itemPath = itemPath
        self.expectedIdentity = expectedIdentity
        self.deliveryMode = deliveryMode
    }

    private enum CodingKeys: String, CodingKey {
        case appIdentifier
        case itemPath
        case expectedIdentity
        case deliveryMode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let appIdentifier = try container.decode(String.self, forKey: .appIdentifier)
        let itemPath = try container.decode(String.self, forKey: .itemPath)
        let expectedIdentity = try container.decode(ApplicationProcessIdentity.self, forKey: .expectedIdentity)
        let deliveryMode = try container.decodeIfPresent(
            DesktopActionOutcome.Delivery.Mode.self,
            forKey: .deliveryMode) ?? .background
        do {
            try self.init(
                appIdentifier: appIdentifier,
                itemPath: itemPath,
                expectedIdentity: expectedIdentity,
                deliveryMode: deliveryMode)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .appIdentifier,
                in: container,
                debugDescription: "Exact menu item identifier contradicts its process identity")
        }
    }
}

/// A recursive application-menu search pinned to the process generation selected by the caller.
public struct MenuItemByNameActionRequest: Sendable, Codable, Equatable {
    public let appIdentifier: String
    public let itemName: String
    public let expectedIdentity: ApplicationProcessIdentity
    public let deliveryMode: DesktopActionOutcome.Delivery.Mode

    public init(
        appIdentifier: String,
        itemName: String,
        expectedIdentity: ApplicationProcessIdentity,
        deliveryMode: DesktopActionOutcome.Delivery.Mode = .background) throws
    {
        guard appIdentifier == "PID:\(expectedIdentity.processIdentifier)" else {
            throw PeekabooError.invalidInput(
                "Exact named menu item identifier must match its process-generation identity")
        }
        self.appIdentifier = appIdentifier
        self.itemName = itemName
        self.expectedIdentity = expectedIdentity
        self.deliveryMode = deliveryMode
    }

    private enum CodingKeys: String, CodingKey {
        case appIdentifier
        case itemName
        case expectedIdentity
        case deliveryMode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let appIdentifier = try container.decode(String.self, forKey: .appIdentifier)
        let itemName = try container.decode(String.self, forKey: .itemName)
        let expectedIdentity = try container.decode(ApplicationProcessIdentity.self, forKey: .expectedIdentity)
        let deliveryMode = try container.decodeIfPresent(
            DesktopActionOutcome.Delivery.Mode.self,
            forKey: .deliveryMode) ?? .background
        do {
            try self.init(
                appIdentifier: appIdentifier,
                itemName: itemName,
                expectedIdentity: expectedIdentity,
                deliveryMode: deliveryMode)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .appIdentifier,
                in: container,
                debugDescription: "Exact named menu item identifier contradicts its process identity")
        }
    }
}

/// Additive capability for application-menu mutations pinned to a caller-authorized process generation.
public protocol MenuServiceGenerationPinnedActionResultProviding: MenuServiceActionResultProviding {
    func clickMenuItemActionResult(request: MenuItemActionRequest) async throws -> UIAutomationActionResult<Void>

    func clickMenuItemByNameActionResult(request: MenuItemByNameActionRequest) async throws
        -> UIAutomationActionResult<Void>
}

extension MenuServiceProtocol {
    public func listMenus(request: MenuListRequest) async throws -> MenuStructure {
        let structure = try await self.listMenus(for: request.appIdentifier)
        guard structure.application.processIdentity == request.expectedIdentity else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Application PID \(request.expectedIdentity.processIdentifier) changed generation " +
                    "while listing its menu.",
                hint: "Refresh the application inventory before retrying.").attributed(to: request.expectedIdentity)
        }
        return structure
    }

    public nonisolated func validatedGenerationPinnedMenuResult(
        _ result: UIAutomationActionResult<Void>,
        expectedIdentity: ApplicationProcessIdentity,
        operation: String) throws -> UIAutomationActionResult<Void>
    {
        let receipt = DesktopActionTargetReceipt(
            processIdentifier: expectedIdentity.processIdentifier,
            processStartIdentity: expectedIdentity.processStartIdentity)
        guard let outcome = result.outcome else {
            throw DesktopActionFailure.indeterminate(
                evidence: .completionUnknown,
                message: "\(operation) returned without a canonical outcome.",
                hint: "Observe the intended application before retrying and update the runtime host.")
                .attributed(to: receipt)
        }
        if outcome.state == .refused, outcome.dispatchState == .none {
            return result
        }
        guard result.targetIdentity?.processIdentity == expectedIdentity else {
            let failure = if outcome.dispatchState.mutationDispatched {
                DesktopActionFailure.indeterminate(
                    route: outcome.route,
                    delivery: outcome.delivery,
                    evidence: .completionUnknown,
                    unitCount: outcome.dispatchState.unitCount,
                    message: "\(operation) returned a missing or mismatched process-generation target.",
                    hint: "Observe the intended application before retrying and update the runtime host.")
            } else {
                DesktopActionFailure.preDispatchRefusal(
                    route: outcome.route,
                    reason: .targetUnavailable,
                    message: "\(operation) returned a missing or mismatched process-generation target.",
                    hint: "Refresh the application inventory before retrying.")
            }
            throw failure.attributed(to: receipt)
        }
        return result
    }

    public func clickMenuItemResult(app: String, itemPath: String) async throws -> UIAutomationActionResult<Void> {
        if let results = self as? any MenuServiceActionResultProviding {
            return try await results.clickMenuItemActionResult(app: app, itemPath: itemPath)
        }
        try await self.clickMenuItem(app: app, itemPath: itemPath)
        return UIAutomationActionResult(
            payload: (),
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                evidence: .deliveryAccepted),
            targetIdentity: nil)
    }

    public func clickMenuItemByNameResult(app: String, itemName: String) async throws
        -> UIAutomationActionResult<Void>
    {
        if let results = self as? any MenuServiceActionResultProviding {
            return try await results.clickMenuItemByNameActionResult(app: app, itemName: itemName)
        }
        try await self.clickMenuItemByName(app: app, itemName: itemName)
        return UIAutomationActionResult(
            payload: (),
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                evidence: .deliveryAccepted),
            targetIdentity: nil)
    }

    public func clickMenuExtraResult(title: String) async throws -> UIAutomationActionResult<Void> {
        if let results = self as? any MenuServiceActionResultProviding {
            return try await results.clickMenuExtraActionResult(title: title)
        }
        try await self.clickMenuExtra(title: title)
        return UIAutomationActionResult(
            payload: (),
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                evidence: .deliveryAccepted),
            targetIdentity: nil)
    }

    public func clickMenuBarItemResult(named name: String) async throws -> UIAutomationActionResult<ClickResult> {
        if let results = self as? any MenuServiceActionResultProviding {
            return try await results.clickMenuBarItemActionResult(named: name)
        }
        let payload = try await self.clickMenuBarItem(named: name)
        return UIAutomationActionResult(
            payload: payload,
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .deliveryAccepted),
            targetIdentity: nil)
    }

    public func clickMenuBarItemResult(at index: Int) async throws -> UIAutomationActionResult<ClickResult> {
        if let results = self as? any MenuServiceActionResultProviding {
            return try await results.clickMenuBarItemActionResult(at: index)
        }
        let payload = try await self.clickMenuBarItem(at: index)
        return UIAutomationActionResult(
            payload: payload,
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .deliveryAccepted),
            targetIdentity: nil)
    }

    public func clickMenuBarItemResult(request: MenuBarItemActionRequest) async throws
        -> UIAutomationActionResult<ClickResult>
    {
        guard let exact = self as? any MenuServiceExactLeafActionResultProviding else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .runtimeIncompatible,
                message: "The menu service cannot preserve selected status-item evidence.",
                hint: "Update the selected Peekaboo runtime before retrying.")
        }
        return try await exact.clickMenuBarItemActionResult(request: request)
    }
}

/// Structure representing an application's menu bar
public struct MenuStructure: Sendable, Codable {
    /// Application information
    public let application: ServiceApplicationInfo

    /// Top-level menus
    public let menus: [Menu]

    /// Total number of menu items
    public nonisolated var totalItems: Int {
        self.menus.reduce(0) { $0 + $1.totalItems }
    }

    public init(application: ServiceApplicationInfo, menus: [Menu]) {
        self.application = application
        self.menus = menus
    }
}

/// A menu in the menu bar
public struct Menu: Sendable, Codable {
    /// Menu title
    public let title: String

    /// Owning bundle identifier (inherited from application)
    public let bundleIdentifier: String?

    /// Owning application name
    public let ownerName: String?

    /// Menu items
    public let items: [MenuItem]

    /// Whether the menu is enabled
    public let isEnabled: Bool

    /// Total items including submenu items
    public nonisolated var totalItems: Int {
        self.items.reduce(0) { $0 + 1 + $1.totalSubitems }
    }

    public init(
        title: String,
        bundleIdentifier: String? = nil,
        ownerName: String? = nil,
        items: [MenuItem],
        isEnabled: Bool = true)
    {
        self.title = title
        self.bundleIdentifier = bundleIdentifier
        self.ownerName = ownerName
        self.items = items
        self.isEnabled = isEnabled
    }
}

/// A menu item
public struct MenuItem: Sendable, Codable {
    /// Item title
    public let title: String

    /// Owning bundle identifier
    public let bundleIdentifier: String?

    /// Owning application name
    public let ownerName: String?

    /// Keyboard shortcut if available
    public let keyboardShortcut: KeyboardShortcut?

    /// Whether the item is enabled
    public let isEnabled: Bool

    /// Whether the item is checked/selected
    public let isChecked: Bool

    /// Whether this is a separator
    public let isSeparator: Bool

    /// Submenu items if this is a submenu
    public let submenu: [MenuItem]

    /// Full path to this item (e.g., "File > Recent > Document.txt")
    public let path: String

    /// Total subitems in submenu
    public nonisolated var totalSubitems: Int {
        self.submenu.reduce(0) { $0 + 1 + $1.totalSubitems }
    }

    public init(
        title: String,
        bundleIdentifier: String? = nil,
        ownerName: String? = nil,
        keyboardShortcut: KeyboardShortcut? = nil,
        isEnabled: Bool = true,
        isChecked: Bool = false,
        isSeparator: Bool = false,
        submenu: [MenuItem] = [],
        path: String)
    {
        self.title = title
        self.bundleIdentifier = bundleIdentifier
        self.ownerName = ownerName
        self.keyboardShortcut = keyboardShortcut
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.isSeparator = isSeparator
        self.submenu = submenu
        self.path = path
    }
}

/// Keyboard shortcut information
public struct KeyboardShortcut: Sendable, Codable {
    /// Modifier keys (cmd, shift, option, ctrl)
    public let modifiers: Set<String>

    /// Main key
    public let key: String

    /// Display string (e.g., "⌘C")
    public let displayString: String

    public init(modifiers: Set<String>, key: String, displayString: String) {
        self.modifiers = modifiers
        self.key = key
        self.displayString = displayString
    }

    private enum CodingKeys: String, CodingKey {
        case modifiers
        case key
        case displayString
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.modifiers = try Set(container.decode([String].self, forKey: .modifiers))
        self.key = try container.decode(String.self, forKey: .key)
        self.displayString = try container.decode(String.self, forKey: .displayString)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.modifiers.sorted(), forKey: .modifiers)
        try container.encode(self.key, forKey: .key)
        try container.encode(self.displayString, forKey: .displayString)
    }
}

/// Information about a menu bar item (status bar item)
public struct MenuBarItemInfo: Sendable, Codable {
    /// Title to surface to users
    public let title: String?

    /// Original raw title reported by the system (Item-0, etc.)
    public let rawTitle: String?

    /// Owning bundle identifier, if known
    public let bundleIdentifier: String?

    /// Owning application name or owner string
    public let ownerName: String?

    /// Index in the menu bar
    public let index: Int

    /// Whether it's currently visible
    public let isVisible: Bool

    /// Optional description
    public let description: String?

    /// Bounding rectangle in screen coordinates, if available
    public let frame: CGRect?

    /// Accessibility identifier or other stable identifier if available.
    public let identifier: String?

    /// AXIdentifier, if available from accessibility traversal.
    public let axIdentifier: String?

    /// AXDescription or help text, if available.
    public let axDescription: String?

    /// Raw window ID (CGS/CGWindow) if requested for debugging.
    public let rawWindowID: CGWindowID?

    /// Raw window layer if available (e.g., 24/25 for menu extras).
    public let rawWindowLayer: Int?

    /// Owning process ID for the backing window, if known.
    public let rawOwnerPID: pid_t?

    /// Source used to collect the item (e.g., "cgs", "cgwindow", "ax-control-center").
    public let rawSource: String?

    /// Exact status-item identity and ordered inventory digest for a follow-up mutation.
    public let selectionEvidence: DesktopSelectedLeafEvidence?

    public init(
        title: String?,
        index: Int,
        isVisible: Bool = true,
        description: String? = nil,
        rawTitle: String? = nil,
        bundleIdentifier: String? = nil,
        ownerName: String? = nil,
        frame: CGRect? = nil,
        identifier: String? = nil,
        axIdentifier: String? = nil,
        axDescription: String? = nil,
        rawWindowID: CGWindowID? = nil,
        rawWindowLayer: Int? = nil,
        rawOwnerPID: pid_t? = nil,
        rawSource: String? = nil,
        selectionEvidence: DesktopSelectedLeafEvidence? = nil)
    {
        self.title = title
        self.rawTitle = rawTitle
        self.bundleIdentifier = bundleIdentifier
        self.ownerName = ownerName
        self.index = index
        self.isVisible = isVisible
        self.description = description
        self.frame = frame
        self.identifier = identifier
        self.axIdentifier = axIdentifier
        self.axDescription = axDescription
        self.rawWindowID = rawWindowID
        self.rawWindowLayer = rawWindowLayer
        self.rawOwnerPID = rawOwnerPID
        self.rawSource = rawSource
        self.selectionEvidence = selectionEvidence
    }
}

/// Information about a system menu extra (status bar item)
public struct MenuExtraInfo: Sendable, Codable {
    /// Display title chosen for automation clients (maybe localized/humanized).
    public let title: String

    /// Raw title reported by the OS (may be generic like Item-0).
    public let rawTitle: String?

    /// The owning bundle identifier for the extra, if known.
    public let bundleIdentifier: String?

    /// The owning application name, if available.
    public let ownerName: String?

    /// Position in the menu bar
    public let position: CGPoint

    /// Whether it's currently visible
    public let isVisible: Bool

    /// Optional accessibility identifier for the extra, if known.
    public let identifier: String?

    /// Raw CGWindow ID backing the menu extra if available.
    public let windowID: CGWindowID?

    /// Raw window layer (e.g., 24/25) if available.
    public let windowLayer: Int?

    /// Owning process ID backing the menu extra, if known.
    public let ownerPID: pid_t?

    /// Source used to collect the item (cgs, cgwindow, ax-control-center, ax-menubar).
    public let source: String?

    public init(
        title: String,
        rawTitle: String? = nil,
        bundleIdentifier: String? = nil,
        ownerName: String? = nil,
        position: CGPoint,
        isVisible: Bool = true,
        identifier: String? = nil,
        windowID: CGWindowID? = nil,
        windowLayer: Int? = nil,
        ownerPID: pid_t? = nil,
        source: String? = nil)
    {
        self.title = title
        self.rawTitle = rawTitle
        self.bundleIdentifier = bundleIdentifier
        self.ownerName = ownerName
        self.position = position
        self.isVisible = isVisible
        self.identifier = identifier
        self.windowID = windowID
        self.windowLayer = windowLayer
        self.ownerPID = ownerPID
        self.source = source
    }
}
