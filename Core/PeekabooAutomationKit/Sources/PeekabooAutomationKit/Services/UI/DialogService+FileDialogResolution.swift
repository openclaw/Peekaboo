import AXorcist
import Foundation

@MainActor
extension DialogService {
    func findActiveFileDialogElement(appName: String) -> Element? {
        guard let targetApp = self.runningApplication(matching: appName) else { return nil }
        let appElement = AXApp(targetApp).element

        let windows = appElement.windowsWithTimeout() ?? []
        for window in windows {
            if let candidate = self.findActiveFileDialogCandidate(in: window) {
                return candidate
            }
        }
        return nil
    }

    private func findActiveFileDialogCandidate(in element: Element) -> Element? {
        firstUniqueDepthFirst(
            from: element,
            matching: self.isFileDialogElement,
            children: { self.sheetElements(for: $0) + ($0.children() ?? []) })
    }
}
