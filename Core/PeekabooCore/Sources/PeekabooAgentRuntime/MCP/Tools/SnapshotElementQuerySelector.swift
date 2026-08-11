import PeekabooAutomationKit

enum SnapshotElementQuerySelector {
    static func preferred(in matches: [UIElement]) -> UIElement? {
        matches.first(where: { $0.isActionable }) ?? matches.first(where: { !$0.isOCRSemanticEvidence })
    }
}
