import AppKit
import Foundation

@MainActor
extension DialogService {
    func runningApplication(matching identifier: String) -> NSRunningApplication? {
        if identifier.hasPrefix("PID:"),
           let processIdentifier = pid_t(identifier.dropFirst(4)),
           processIdentifier > 0
        {
            return NSRunningApplication(processIdentifier: processIdentifier)
        }

        let lowered = identifier.lowercased()
        return NSWorkspace.shared.runningApplications.first {
            if let name = $0.localizedName?.lowercased(),
               name == lowered || name.contains(lowered)
            {
                return true
            }
            if let bundle = $0.bundleIdentifier?.lowercased(),
               bundle == lowered || bundle.contains(lowered)
            {
                return true
            }
            return false
        }
    }
}
