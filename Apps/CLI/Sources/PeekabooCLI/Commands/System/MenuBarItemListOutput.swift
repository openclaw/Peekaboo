import Foundation
import PeekabooCore

enum MenuBarItemListOutput {
    struct Payload: Codable {
        let items: [MenuBarItemInfo]
        let menu_bar_items: [MenuBarItemInfo]
        let count: Int

        init(items: [MenuBarItemInfo]) {
            self.items = items
            self.menu_bar_items = items
            self.count = items.count
        }
    }

    @MainActor
    static func outputJSON(items: [MenuBarItemInfo], logger: Logger) {
        outputSuccessCodable(
            data: Payload(items: items),
            logger: logger
        )
    }

    @MainActor
    static func display(_ items: [MenuBarItemInfo]) {
        if items.isEmpty {
            Swift.print("No menu bar items detected.")
            return
        }

        Swift.print("Menu Bar Items (\(items.count)):")
        for item in items {
            self.display(item)
        }
    }

    @MainActor
    private static func display(_ item: MenuBarItemInfo) {
        let title = item.title ?? "<untitled>"
        Swift.print("  [\(item.index)] \(title)")
        if let description = item.description, !description.isEmpty {
            Swift.print("       Description: \(description)")
        }
        if let frame = item.frame {
            let frameOrigin = "\(Int(frame.origin.x)),\(Int(frame.origin.y))"
            let frameSize = "\(Int(frame.width))×\(Int(frame.height))"
            Swift.print("       Frame: \(frameOrigin) \(frameSize)")
        }
    }
}
