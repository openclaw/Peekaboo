//
//  CommunicationToolFormatter.swift
//  PeekabooCore
//

import Foundation

/// Formatter for communication tools (task_completed, need_more_information, etc.)
public class CommunicationToolFormatter: BaseToolFormatter {
    override public func formatCompactSummary(arguments: [String: Any]) -> String {
        // Communication tools typically don't need argument summaries
        ""
    }

    override public func formatResultSummary(result: [String: Any]) -> String {
        // Communication tools don't typically show result summaries
        // Their content is displayed as assistant messages instead
        ""
    }

    override public func formatStarting(arguments: [String: Any]) -> String {
        switch toolType {
        case .done, .taskCompleted:
            "Completing task..."

        case .needMoreInformation, .needInfo:
            "Requesting information..."

        default:
            super.formatStarting(arguments: arguments)
        }
    }

    override public func formatCompleted(result: [String: Any], duration: TimeInterval) -> String {
        // Communication tools typically don't show completion messages
        // since their content is displayed as assistant text
        ""
    }
}
