import Foundation
import Testing
@testable import PeekabooAgentRuntime

@Suite("UI snapshot session ownership")
struct UISnapshotStoreOwnerTests {
    @Test
    func `contexts isolate by default and share only through the explicit legacy helper`() async {
        let first = await MCPToolTestHelpers.makeContext()
        let second = await MCPToolTestHelpers.makeContext()
        let firstLegacy = await MCPToolTestHelpers.makeLegacyContext()
        let secondLegacy = await MCPToolTestHelpers.makeLegacyContext()

        #expect(first.uiSnapshots.owner != second.uiSnapshots.owner)
        #expect(firstLegacy.uiSnapshots.owner == .legacyProcess)
        #expect(firstLegacy.uiSnapshots.owner == secondLegacy.uiSnapshots.owner)
    }

    @Test
    func `identical external IDs remain distinct per owner`() async {
        let manager = UISnapshotManager(maximumRetainedSnapshots: 2)
        let first = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner(), manager: manager)
        let second = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner(), manager: manager)

        let firstSnapshot = await first.createSnapshot(id: "shared-id")
        let secondSnapshot = await second.createSnapshot(id: "shared-id")

        #expect(firstSnapshot !== secondSnapshot)
        #expect(await first.getSnapshot(id: "shared-id") === firstSnapshot)
        #expect(await second.getSnapshot(id: "shared-id") === secondSnapshot)
    }

    @Test
    func `capacity eviction is isolated to one owner`() async {
        let manager = UISnapshotManager(maximumRetainedSnapshots: 2)
        let first = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner(), manager: manager)
        let second = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner(), manager: manager)
        let retained = await first.createSnapshot(id: "first-retained", at: Date(timeIntervalSince1970: 1))

        _ = await second.createSnapshot(id: "second-old", at: Date(timeIntervalSince1970: 1))
        _ = await second.createSnapshot(id: "second-middle", at: Date(timeIntervalSince1970: 2))
        _ = await second.createSnapshot(id: "second-new", at: Date(timeIntervalSince1970: 3))

        #expect(await first.getSnapshot(id: retained.id) === retained)
        #expect(await second.getSnapshot(id: "second-old") == nil)
        #expect(await second.getSnapshot(id: "second-middle") != nil)
        #expect(await second.getSnapshot(id: "second-new") != nil)
    }

    @Test
    func `failure cleanup and remove all cannot delete another owner`() async {
        let manager = UISnapshotManager(maximumRetainedSnapshots: 2)
        let first = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner(), manager: manager)
        let second = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner(), manager: manager)
        let secondSnapshot = await second.createSnapshot(id: "same-failure-id")
        _ = await first.createSnapshot(id: "same-failure-id")

        await first.removeSnapshot(id: "same-failure-id")
        #expect(await first.getSnapshot(id: "same-failure-id") == nil)
        #expect(await second.getSnapshot(id: "same-failure-id") === secondSnapshot)

        _ = await first.createSnapshot(id: "temporary")
        await first.removeAllSnapshots()
        #expect(await first.getSnapshot(id: nil) == nil)
        #expect(await second.getSnapshot(id: "same-failure-id") === secondSnapshot)
    }

    @Test
    func `owner lifecycle cleanup releases only its namespace`() async {
        let manager = UISnapshotManager(maximumRetainedSnapshots: 2)
        let first = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner(), manager: manager)
        let second = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner(), manager: manager)
        _ = await first.createSnapshot(id: "first")
        let secondSnapshot = await second.createSnapshot(id: "second")
        #expect(await manager.retainedOwnerCountForTesting() == 2)

        await first.removeOwner()
        #expect(await first.getSnapshot(id: "first") == nil)
        #expect(await second.getSnapshot(id: "second") === secondSnapshot)
        #expect(await manager.retainedOwnerCountForTesting() == 1)

        await second.removeOwner()
        #expect(await manager.retainedOwnerCountForTesting() == 0)
    }

    @Test
    func `stale Agent release cannot remove a reused live session`() async {
        let manager = UISnapshotManager(maximumRetainedSnapshots: 2)
        let first = MCPToolUISnapshotStore(
            owner: MCPToolSnapshotOwner(sessionID: "reused-session"),
            manager: manager)
        let resumed = MCPToolUISnapshotStore(
            owner: MCPToolSnapshotOwner(sessionID: "reused-session"),
            manager: manager)
        await first.retainOwner()
        _ = await first.createSnapshot(id: "first-turn")
        await resumed.retainOwner()
        let resumedSnapshot = await resumed.createSnapshot(id: "resumed-turn")

        await first.releaseOwner()

        #expect(await resumed.getSnapshot(id: "resumed-turn") === resumedSnapshot)
        #expect(await manager.retainedOwnerCountForTesting() == 1)

        await resumed.releaseOwner()
        #expect(await resumed.getSnapshot(id: "resumed-turn") == nil)
        #expect(await manager.retainedOwnerCountForTesting() == 0)
    }

    @Test
    func `invalidation pending and preservation state are per owner`() async {
        let manager = UISnapshotManager(maximumRetainedSnapshots: 2)
        let first = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner(), manager: manager)
        let second = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner(), manager: manager)
        let creation = Date(timeIntervalSince1970: 100)
        let cutoff = Date(timeIntervalSince1970: 200)
        let firstSnapshot = await first.createSnapshot(id: "pending", at: creation, pending: true)
        let secondSnapshot = await second.createSnapshot(id: "pending", at: creation)

        #expect(await first.getSnapshot(id: nil) == nil)
        #expect(await second.getSnapshot(id: nil) === secondSnapshot)

        _ = await first.invalidateImplicitLatestSnapshot(
            through: cutoff,
            preserving: firstSnapshot.id,
            preservedAt: Date(timeIntervalSince1970: 300))

        #expect(await first.getSnapshot(id: nil) === firstSnapshot)
        #expect(await first.getSnapshot(id: firstSnapshot.id) === firstSnapshot)
        #expect(await second.getSnapshot(id: nil) === secondSnapshot)

        _ = await first.invalidateImplicitLatestSnapshot(through: Date(timeIntervalSince1970: 400))
        #expect(await first.getSnapshot(id: nil) == nil)
        #expect(await first.getSnapshot(id: firstSnapshot.id) === firstSnapshot)
        #expect(await second.getSnapshot(id: nil) === secondSnapshot)
    }

    @Test
    func `implicit latest never crosses owner namespaces`() async {
        let manager = UISnapshotManager(maximumRetainedSnapshots: 2)
        let first = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner(), manager: manager)
        let second = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner(), manager: manager)
        let firstSnapshot = await first.createSnapshot(id: "first", at: Date(timeIntervalSince1970: 10))
        let secondSnapshot = await second.createSnapshot(id: "second", at: Date(timeIntervalSince1970: 20))

        #expect(await first.getSnapshot(id: nil) === firstSnapshot)
        #expect(await second.getSnapshot(id: nil) === secondSnapshot)
        #expect(await first.getSnapshot(id: secondSnapshot.id) == nil)
        #expect(await second.getSnapshot(id: firstSnapshot.id) == nil)
    }
}
