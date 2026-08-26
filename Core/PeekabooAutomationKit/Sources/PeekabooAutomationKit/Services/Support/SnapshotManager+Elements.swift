import Foundation

extension SnapshotManager {
    /// Get element by ID from snapshot
    public func getElement(snapshotId: String, elementId: String) async throws -> UIElement? {
        guard let snapshotPath = try self.ownedSnapshotURL(for: snapshotId) else {
            throw SnapshotError.snapshotNotFound
        }
        guard let snapshotData = await self.snapshotActor.loadSnapshot(snapshotId: snapshotId, from: snapshotPath)
        else {
            throw SnapshotError.snapshotNotFound
        }
        return snapshotData.uiMap[elementId]
    }

    /// Find elements matching a query
    public func findElements(snapshotId: String, matching query: String) async throws -> [UIElement] {
        guard let snapshotPath = try self.ownedSnapshotURL(for: snapshotId) else {
            throw SnapshotError.snapshotNotFound
        }
        guard let snapshotData = await self.snapshotActor.loadSnapshot(snapshotId: snapshotId, from: snapshotPath)
        else {
            throw SnapshotError.snapshotNotFound
        }

        let lowercaseQuery = query.lowercased()
        return snapshotData.uiMap.values.filter { element in
            let searchableText = [
                element.title,
                element.label,
                element.value,
                element.role,
            ].compactMap(\.self).joined(separator: " ").lowercased()

            return searchableText.contains(lowercaseQuery)
        }.sorted { lhs, rhs in
            if abs(lhs.frame.origin.y - rhs.frame.origin.y) < 10 {
                return lhs.frame.origin.x < rhs.frame.origin.x
            }
            return lhs.frame.origin.y < rhs.frame.origin.y
        }
    }

    public func getUIAutomationSnapshot(snapshotId: String) async throws -> UIAutomationSnapshot? {
        guard let snapshotPath = try self.ownedSnapshotURL(for: snapshotId) else { return nil }
        return await self.snapshotActor.loadSnapshot(snapshotId: snapshotId, from: snapshotPath)
    }
}
