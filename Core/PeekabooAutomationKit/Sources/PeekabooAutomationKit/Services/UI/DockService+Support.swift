import AppKit
@preconcurrency import AXorcist
import PeekabooFoundation

struct DockGenerationBoundElement {
    let identity: ApplicationProcessIdentity
    let element: Element
    let evidence: DesktopSelectedLeafEvidence
}

struct DockLeafSnapshot {
    let element: Element
    let index: Int
    let title: String
    let identifier: String?
    let role: String
    let subrole: String?
    let frame: CGRect
    let url: String?
}

@MainActor
extension DockService {
    static func checkDockDispatchCancellation(
        _ checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws
    {
        do {
            try checkCancellation()
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .requestCancelled,
                message: "Dock action was cancelled before event submission.",
                hint: "Submit a new request only if the Dock action is still wanted.")
        }
    }

    func findDockRunningApplication() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.apple.dock"
        }
    }

    func findDockApplication() -> Element? {
        guard let dockApp = self.findDockRunningApplication() else { return nil }
        return AXApp(dockApp).element
    }

    func validateDockProcessIdentity(_ identity: ApplicationProcessIdentity) throws {
        guard self.findDockRunningApplication()?.processIdentifier == identity.processIdentifier,
              SystemIdentityResolver.processStartIdentity(identity.processIdentifier) ==
              identity.processStartIdentity
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Dock changed process generation before dispatch",
                hint: "Resolve the current Dock generation before retrying.")
        }
    }

    func resolveDockElement(appName: String) throws -> DockGenerationBoundElement {
        guard let dockApp = self.findDockRunningApplication() else {
            throw DockError.dockNotFound
        }
        guard let processStartIdentity = SystemIdentityResolver.processStartIdentity(dockApp.processIdentifier) else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Dock has no stable owner process; refusing to dispatch",
                hint: "Resolve the current Dock generation before retrying.")
        }
        let identity = ApplicationProcessIdentity(
            processIdentifier: dockApp.processIdentifier,
            processStartIdentity: processStartIdentity)
        let snapshots = try self.dockLeafSnapshots(in: AXApp(dockApp).element)
        let selection = try Self.selectDockLeaf(named: appName, snapshots: snapshots)
        try self.validateDockProcessIdentity(identity)
        let evidence = try Self.dockLeafEvidence(
            selection: selection,
            processIdentity: identity,
            kind: .dockItem)
        return DockGenerationBoundElement(
            identity: identity,
            element: selection.candidate.value.element,
            evidence: evidence)
    }

    func findDockElement(appName: String) throws -> Element {
        guard let dock = self.findDockApplication() else {
            throw DockError.dockNotFound
        }
        return try self.findDockElement(appName: appName, in: dock)
    }

    private func findDockElement(appName: String, in dock: Element) throws -> Element {
        let snapshots = try self.dockLeafSnapshots(in: dock)
        return try Self.selectDockLeaf(named: appName, snapshots: snapshots).candidate.value.element
    }

    func dockLeafSnapshots(in dock: Element) throws -> [DockLeafSnapshot] {
        guard let dockList = dock.children()?.first(where: { $0.role() == "AXList" }) else {
            throw DockError.dockListNotFound
        }
        return (dockList.children() ?? []).indexed().compactMap { index, element in
            guard let title = element.title()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty,
                  let frame = element.frame(),
                  !frame.isEmpty
            else { return nil }
            return DockLeafSnapshot(
                element: element,
                index: index,
                title: title,
                identifier: element.identifier(),
                role: element.role() ?? "AXDockItem",
                subrole: element.subrole(),
                frame: frame,
                url: element.url()?.absoluteString)
        }
    }

    static func selectDockLeaf(
        named name: String,
        snapshots: [DockLeafSnapshot]) throws
        -> DeterministicDesktopLeafSelector.Selection<DockLeafSnapshot>
    {
        let candidates = snapshots.map { snapshot in
            DeterministicDesktopLeafSelector.Candidate(
                value: snapshot,
                index: snapshot.index,
                displayName: snapshot.title,
                matchFields: [snapshot.title],
                stableIdentity: DeterministicDesktopLeafSelector.stableIdentity([
                    snapshot.title,
                    snapshot.identifier,
                    snapshot.role,
                    snapshot.subrole,
                    snapshot.url,
                    Self.canonicalDockFrame(snapshot.frame),
                ]))
        }
        do {
            return try DeterministicDesktopLeafSelector.select(named: name, from: candidates)
        } catch let error as DesktopLeafSelectionError {
            switch error {
            case .notFound:
                throw DockError.itemNotFound(name)
            case let .ambiguous(_, matches):
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .invalidRequest,
                    message: "Dock item selector '\(name)' is ambiguous: \(matches.joined(separator: ", ")).",
                    hint: "Use the exact Dock item title shown by 'peekaboo dock list'.")
            case .invalidIndex:
                throw DockError.itemNotFound(name)
            }
        }
    }

    static func dockLeafEvidence(
        selection: DeterministicDesktopLeafSelector.Selection<DockLeafSnapshot>,
        processIdentity: ApplicationProcessIdentity,
        kind: DesktopSelectedLeafEvidence.Kind) throws -> DesktopSelectedLeafEvidence
    {
        let snapshot = selection.candidate.value
        return try DesktopSelectedLeafEvidence(
            kind: kind,
            normalizedSelector: selection.normalizedSelector,
            matchKind: selection.matchKind,
            selectedProcessIdentity: processIdentity,
            selectedIndex: snapshot.index,
            selectedTitle: snapshot.title,
            selectedIdentifier: snapshot.identifier,
            selectedRole: snapshot.role,
            selectedSubrole: snapshot.subrole,
            selectedFrame: snapshot.frame,
            candidateSetSHA256: selection.candidateSetSHA256,
            candidateCount: selection.candidateCount)
    }

    static func validateDockLeafRefresh(
        expected: DockGenerationBoundElement,
        refreshed: DockGenerationBoundElement,
        appName: String) throws
    {
        guard expected.identity == refreshed.identity,
              expected.element == refreshed.element,
              expected.evidence.hasSameResolvedLeaf(as: refreshed.evidence)
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Dock item '\(appName)' changed identity or order before dispatch.",
                hint: "Refresh the Dock inventory before retrying.")
        }
    }

    private static func canonicalDockFrame(_ frame: CGRect) -> String {
        [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]
            .map { String(format: "%016llx", Double($0).bitPattern) }
            .joined(separator: ":")
    }
}
