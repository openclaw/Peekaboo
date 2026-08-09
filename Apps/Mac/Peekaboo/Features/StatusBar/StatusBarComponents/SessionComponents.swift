import Foundation
import PeekabooCore
import Tachikoma

// MARK: - Helper Functions

func formatSessionDuration(_ session: ConversationSession) -> String {
    let duration: TimeInterval = if let lastMessage = session.messages.last {
        lastMessage.timestamp.timeIntervalSince(session.startTime)
    } else {
        Date().timeIntervalSince(session.startTime)
    }

    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute, .second]
    formatter.unitsStyle = .abbreviated
    formatter.maximumUnitCount = 2

    return formatter.string(from: duration) ?? "0s"
}
