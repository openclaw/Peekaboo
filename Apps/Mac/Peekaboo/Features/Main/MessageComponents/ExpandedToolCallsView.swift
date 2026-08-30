import PeekabooCore
import SwiftUI

// MARK: - Expanded Tool Calls View

struct ExpandedToolCallsView: View {
    let toolCalls: [ConversationToolCall]
    let onImageTap: (NSImage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(self.toolCalls) { toolCall in
                VStack(alignment: .leading, spacing: 8) {
                    // Arguments
                    if !toolCall.arguments.isEmpty, toolCall.arguments != "{}" {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Arguments")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Text(toolCall.arguments.formatJSON())
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                                .background(Color(NSColor.textBackgroundColor))
                                .cornerRadius(4)
                        }
                    }

                    // Result
                    if !toolCall.result.isEmpty, toolCall.result != "Running..." {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Result")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            // Check if result contains image data
                            if toolCall.name.contains("image") || toolCall.name.contains("screenshot"),
                               let imageData = toolCall.result.extractImageData(),
                               let image = NSImage(data: imageData)
                            {
                                Button(action: {
                                    self.onImageTap(image)
                                }, label: {
                                    Image(nsImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxHeight: 200)
                                        .cornerRadius(8)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                                })
                                .buttonStyle(.plain)
                                .help("Click to inspect image")
                            } else {
                                Text(toolCall.result)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(10)
                                    .padding(8)
                                    .background(Color(NSColor.textBackgroundColor))
                                    .cornerRadius(4)
                            }
                        }
                    }
                }
            }
        }
    }
}
