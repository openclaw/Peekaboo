import AppKit
import Foundation
import PeekabooFoundation

/// Selector metadata remains authoritative even when a live application's process identity is unavailable.
struct RunningApplicationSelectorCensus {
    struct Entry {
        let application: NSRunningApplication
        let processIdentifier: pid_t?
        let candidate: ApplicationIdentifierMatcher.Candidate

        init(
            _ application: NSRunningApplication,
            processIdentifierResolver: ApplicationService.ApplicationProcessIdentifierResolver =
                RunningApplicationProcessIdentity.resolve)
        {
            self.application = application
            self.processIdentifier = processIdentifierResolver(application).flatMap { $0 > 0 ? $0 : nil }
            // The AppKit missing-PID sentinel participates only in metadata matching and its digest.
            // It must never become a selectable PID, a suggested target, or a dispatch identity.
            self.candidate = .init(
                processIdentifier: self.processIdentifier ?? -1,
                bundleIdentifier: application.bundleIdentifier,
                name: application.localizedName ?? application.bundleIdentifier ?? "Unknown",
                bundlePath: application.bundleURL?.path,
                executablePath: application.executableURL?.path,
                allowsFuzzyMatching: application.activationPolicy != .prohibited,
                isRegularApplication: application.activationPolicy == .regular)
        }
    }

    struct InventorySeed: Sendable {
        let processIdentifiers: [pid_t]
        let omissionWarnings: [String]
    }

    let entries: [Entry]

    init(
        applications: [NSRunningApplication],
        processIdentifierResolver: ApplicationService.ApplicationProcessIdentifierResolver =
            RunningApplicationProcessIdentity.resolve)
    {
        self.entries = applications.filter { !$0.isTerminated }.map {
            Entry($0, processIdentifierResolver: processIdentifierResolver)
        }
    }

    var candidates: [ApplicationIdentifierMatcher.Candidate] {
        self.entries.map(\.candidate)
    }

    var inventorySeed: InventorySeed {
        InventorySeed(
            processIdentifiers: self.entries.compactMap(\.processIdentifier),
            omissionWarnings: self.entries.filter { $0.processIdentifier == nil }.map {
                "Application '\($0.candidate.name)' lacked a verified process identifier and was omitted."
            })
    }

    func resolve(identifier: String) throws
        -> (
            application: NSRunningApplication,
            processIdentifier: pid_t,
            resolution: ApplicationIdentifierMatcher.Resolution)
    {
        guard let resolution = try ApplicationIdentifierMatcher.resolution(for: identifier, in: self.candidates) else {
            throw PeekabooError.appNotFound(identifier)
        }
        guard !resolution.hasWinningTie else {
            throw PeekabooError.ambiguousAppIdentifier(identifier, suggestions: resolution.ambiguitySuggestions)
        }
        let entry = self.entries[resolution.index]
        guard let processIdentifier = entry.processIdentifier else {
            throw PeekabooError.commandFailed(
                "Application '\(identifier)' matched, but its process identity could not be verified; " +
                    "retry after the application's process identity becomes available")
        }
        return (entry.application, processIdentifier, resolution)
    }
}
