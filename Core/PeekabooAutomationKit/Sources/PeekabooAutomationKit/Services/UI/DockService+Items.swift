import AppKit
@preconcurrency import AXorcist
import Foundation
import PeekabooFoundation

@MainActor
extension DockService {
    func listDockItemsImpl(includeAll: Bool = false) async throws -> [DockItem] {
        guard let dock = findDockApplication() else {
            throw PeekabooError.operationError(message: "Dock application not found or not running.")
        }

        guard let dockList = dock.children()?.first(where: { $0.role() == "AXList" }) else {
            throw PeekabooError.operationError(message: "Dock item list not found.")
        }

        let dockElements = dockList.children() ?? []
        var items: [DockItem] = []

        for (index, element) in dockElements.indexed() {
            guard let item = self.makeDockItem(from: element, index: index, includeAll: includeAll) else {
                continue
            }
            items.append(item)
        }

        return items
    }

    func findDockItemImpl(name: String) async throws -> DockItem {
        let items = try await listDockItems(includeAll: false)
        let candidates = items.map { item in
            DeterministicDesktopLeafSelector.Candidate(
                value: item,
                index: item.index,
                displayName: item.title,
                matchFields: [item.title],
                stableIdentity: DeterministicDesktopLeafSelector.stableIdentity([
                    item.title,
                    item.itemType.rawValue,
                    item.bundleIdentifier,
                    item.position.map { "\($0.x),\($0.y)" },
                    item.size.map { "\($0.width),\($0.height)" },
                ]))
        }
        do {
            return try DeterministicDesktopLeafSelector.select(named: name, from: candidates).candidate.value
        } catch let error as DesktopLeafSelectionError {
            switch error {
            case .notFound, .invalidIndex:
                throw DockError.itemNotFound(name)
            case let .ambiguous(_, matches):
                throw PeekabooError.invalidInput(
                    "Dock item selector '\(name)' is ambiguous: \(matches.joined(separator: ", ")). " +
                        "Use the exact Dock item title shown by 'peekaboo dock list'.")
            }
        }
    }

    private func makeDockItem(from element: Element, index: Int, includeAll: Bool) -> DockItem? {
        let role = element.role() ?? ""
        let title = element.title() ?? ""
        let subrole = element.subrole() ?? ""

        let itemType = self.determineItemType(role: role, subrole: subrole, title: title)
        if itemType == .separator, !includeAll {
            return nil
        }

        let position = element.position()
        let size = element.size()

        var isRunning: Bool?
        if itemType == .application {
            isRunning = element.attribute(Attribute<Bool>("AXIsApplicationRunning"))
        }

        let bundleIdentifier: String? = if itemType == .application, !title.isEmpty {
            self.findBundleIdentifier(for: title)
        } else {
            nil
        }

        return DockItem(
            index: index,
            title: title,
            itemType: itemType,
            isRunning: isRunning,
            bundleIdentifier: bundleIdentifier,
            position: position,
            size: size)
    }

    private func determineItemType(role: String, subrole: String, title: String) -> DockItemType {
        if role == "AXSeparator" || subrole == "AXSeparator" {
            return .separator
        }

        switch subrole {
        case "AXApplicationDockItem":
            return .application
        case "AXFolderDockItem":
            return .folder
        case "AXFileDockItem":
            return .file
        case "AXURLDockItem":
            return .url
        case "AXMinimizedWindowDockItem":
            return .minimizedWindow
        default:
            break
        }

        let normalizedTitle = title.lowercased()
        if normalizedTitle == "trash" || normalizedTitle == "bin" {
            return .trash
        }
        return .unknown
    }

    private func findBundleIdentifier(for appName: String) -> String? {
        let workspace = NSWorkspace.shared

        if let runningApp = workspace.runningApplications.first(where: {
            $0.localizedName == appName || $0.localizedName?.contains(appName) == true
        }) {
            return runningApp.bundleIdentifier
        }

        let searchPaths = [
            "/Applications",
            "/System/Applications",
            "/Applications/Utilities",
            "~/Applications",
        ].map { NSString(string: $0).expandingTildeInPath }

        let fileManager = FileManager.default

        for path in searchPaths {
            let searchName = appName.hasSuffix(".app") ? appName : "\(appName).app"
            let fullPath = (path as NSString).appendingPathComponent(searchName)

            if fileManager.fileExists(atPath: fullPath),
               let bundle = Bundle(path: fullPath)
            {
                return bundle.bundleIdentifier
            }
        }

        return nil
    }
}
