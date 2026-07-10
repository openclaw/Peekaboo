import Combine
import Foundation
import SwiftUI

// MARK: - Helper Functions

func formatModelName(_ model: String) -> String {
    // Shorten common model names for display
    switch model {
    case "gpt-5.6-sol": "GPT-5.6 Sol"
    case "gpt-5.6-terra": "GPT-5.6 Terra"
    case "gpt-5.6-luna": "GPT-5.6 Luna"
    case "gpt-5.5": "GPT-5.5"
    case "gpt-5.4": "GPT-5.4"
    case "gpt-5.4-mini": "GPT-5.4 mini"
    case "gpt-5.4-nano": "GPT-5.4 nano"
    case "gpt-5": "GPT-5"
    case "gpt-5-mini": "GPT-5 mini"
    case "claude-fable-5": "Claude Fable 5"
    case "claude-sonnet-5": "Claude Sonnet 5"
    case "claude-opus-4-8": "Claude Opus 4.8"
    case "claude-opus-4-7": "Claude Opus 4.7"
    case "claude-sonnet-4-6": "Claude Sonnet 4.6"
    case "claude-sonnet-4-5-20250929": "Claude Sonnet 4.5"
    case "claude-haiku-4.5": "Claude Haiku 4.5"
    case "grok-4.3": "Grok 4.3"
    case "gemini-3.5-flash": "Gemini 3.5 Flash"
    case "llava:latest": "LLaVA"
    case "llama3.2-vision:latest": "Llama 3.2"
    default: model
    }
}

// MARK: - Time Formatting Components

struct SessionDurationText: View {
    let startTime: Date
    @State private var currentTime = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(self.formatDuration(self.currentTime.timeIntervalSince(self.startTime)))
            .onReceive(self.timer) { _ in
                self.currentTime = Date()
            }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        if interval < 60 {
            return "\(Int(interval))s"
        } else if interval < 3600 {
            let minutes = Int(interval) / 60
            let seconds = Int(interval) % 60
            return "\(minutes)m \(seconds)s"
        } else {
            let hours = Int(interval) / 3600
            let minutes = (Int(interval) % 3600) / 60
            if minutes > 0 {
                return "\(hours)h \(minutes)m"
            } else {
                return "\(hours)h"
            }
        }
    }
}

// MARK: - Data Extraction Utilities

extension String {
    func extractImageData() -> Data? {
        // Try to extract base64 image data from result
        if let data = self.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let screenshotData = json["screenshot_data"] as? String,
           let imageData = Data(base64Encoded: screenshotData)
        {
            return imageData
        }
        return nil
    }

    func formatJSON() -> String {
        guard let data = self.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let formattedData = try? JSONSerialization.data(
                  withJSONObject: jsonObject,
                  options: [.prettyPrinted, .sortedKeys]),
              let formattedString = String(data: formattedData, encoding: .utf8)
        else {
            return self
        }
        return formattedString
    }
}

// MARK: - Visual Effect View

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = self.material
        view.blendingMode = self.blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = self.material
        nsView.blendingMode = self.blendingMode
    }
}
