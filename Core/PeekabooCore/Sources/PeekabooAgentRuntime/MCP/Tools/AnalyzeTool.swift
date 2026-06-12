import Foundation
import MCP
import os.log
import PeekabooAutomation
import PeekabooFoundation
import Tachikoma
import TachikomaMCP

/// MCP tool for analyzing images with AI
public struct AnalyzeTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "AnalyzeTool")

    public let name = "analyze"

    public var description: String {
        """
        Analyzes a pre-existing image file from the local filesystem using a configured AI model.

        This tool is useful when an image already exists (e.g., previously captured, downloaded, or generated)
        and you need to understand its content, extract text, or answer specific questions about it.

        Capabilities:
        - Image Understanding: Provide any question about the image (e.g., "What objects are in this picture?",
          "Describe the scene.", "Is there a red car?").
        - Text Extraction (OCR): Ask the AI to extract text from the image
          (e.g., "What text is visible in this screenshot?").
        - Flexible AI Configuration: Can use server-default AI providers/models or specify a particular one per call
          via 'provider_config'.

        Example:
        If you have an image '/tmp/chart.png' showing a bar chart, you could ask:
        { "image_path": "/tmp/chart.png", "question": "Which category has the highest value in this bar chart?" }
        The AI will analyze the image and attempt to answer your question based on its visual content.

        \(PeekabooMCPVersion.banner) using openai/gpt-5.5, anthropic/claude-opus-4-8
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "image_path": SchemaBuilder.string(
                    description: "Required. Absolute path to image file (.png, .jpg, .webp) to be analyzed."),
                "question": SchemaBuilder.string(
                    description: "Required. Question for the AI about the image."),
                "provider_config": SchemaBuilder.object(
                    properties: [
                        "type": SchemaBuilder.string(
                            description: "AI provider, default: auto. 'auto' uses server's",
                            enum: ["auto", "ollama", "openai", "anthropic", "grok"],
                            default: "auto"),
                        "model": SchemaBuilder.string(
                            description: "Optional. Model name. If omitted, uses server defaults."),
                    ],
                    description: "Optional provider/model. Validated against server defaults."),
            ],
            required: ["question"])
    }

    public init() {}

    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        // Get required parameters
        guard let imagePath = arguments.getString("image_path") else {
            return ToolResponse.error("Missing required parameter: image_path")
        }

        guard let question = arguments.getString("question") else {
            return ToolResponse.error("Missing required parameter: question")
        }

        // Validate image file extension and determine media type
        let fileExtension = (imagePath as NSString).pathExtension.lowercased()
        let supportedFormats = ["png", "jpg", "jpeg", "webp"]
        guard supportedFormats.contains(fileExtension) else {
            return ToolResponse
                .error("Unsupported image format: .\(fileExtension). Supported formats: .png, .jpg, .jpeg, .webp")
        }

        // Check if file exists
        let expandedPath = (imagePath as NSString).expandingTildeInPath
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: expandedPath) else {
            return ToolResponse.error("Image file not found: \(imagePath)")
        }

        let modelOverride: LanguageModel?
        do {
            modelOverride = try Self.modelOverride(from: arguments)
        } catch {
            return ToolResponse.error("Invalid provider_config: \(error.localizedDescription)")
        }

        do {
            self.logger.info("Analyzing image with \(modelOverride?.description ?? "configured default")")
            let startTime = Date()

            let aiService = await MainActor.run { PeekabooAIService() }
            let analysis = try await aiService.analyzeImageFileDetailed(
                at: expandedPath,
                question: question,
                model: modelOverride)

            let duration = Date().timeIntervalSince(startTime)
            self.logger.info("Analysis completed in \(String(format: "%.2f", duration))s")

            let timingMessage = [
                "",
                "👻 Peekaboo: Analyzed image with \(analysis.provider)/\(analysis.model)",
                "in \(String(format: "%.2f", duration))s.",
            ].joined(separator: " ")

            let baseMeta: [String: Value] = [
                "image_path": .string(imagePath),
                "question": .string(question),
                "provider": .string(analysis.provider),
                "model": .string(analysis.model),
                "execution_time": .double(duration),
            ]
            let summary = ToolEventSummary(
                actionDescription: "Image Analyze",
                notes: question)

            return ToolResponse(
                content: [
                    .text(text: analysis.text, annotations: nil, _meta: nil),
                    .text(text: timingMessage, annotations: nil, _meta: nil),
                ],
                meta: ToolEventSummary.merge(summary: summary, into: .object(baseMeta)))

        } catch {
            self.logger.error("Analysis failed: \(error)")
            return ToolResponse.error("AI analysis failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    static func modelOverride(from arguments: ToolArguments) throws -> LanguageModel? {
        struct Input: Decodable {
            struct ProviderConfig: Decodable {
                let type: String?
                let model: String?
            }

            let providerConfig: ProviderConfig?

            enum CodingKeys: String, CodingKey {
                case providerConfig = "provider_config"
            }
        }

        let input = try arguments.decode(Input.self)
        guard let config = input.providerConfig else {
            return nil
        }

        return try self.languageModel(providerType: config.type, modelName: config.model)
    }

    static func languageModel(providerType: String?, modelName: String?) throws -> LanguageModel? {
        let provider = providerType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let model = modelName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        guard let provider, !provider.isEmpty, provider != "auto" else {
            guard let model else { return nil }
            guard let parsed = LanguageModel.parse(from: model) else {
                throw PeekabooError.invalidInput("Unknown model: \(model)")
            }
            return parsed
        }

        switch provider {
        case "openai":
            guard let model else { return .openai(.gpt55) }
            if Self.isUnsupportedLegacyModel(provider: provider, model: model) {
                throw PeekabooError.invalidInput("Unsupported OpenAI model: \(model)")
            }
            if let parsed = LanguageModel.parse(from: model), case .openai = parsed {
                return parsed
            }
            return .openai(.custom(model))
        case "anthropic":
            guard let model else { return .anthropic(.opus48) }
            if Self.isUnsupportedLegacyModel(provider: provider, model: model) {
                throw PeekabooError.invalidInput("Unsupported Anthropic model: \(model)")
            }
            if let parsed = LanguageModel.parse(from: model), case .anthropic = parsed {
                return parsed
            }
            return .anthropic(.custom(model))
        case "grok", "xai":
            guard let model else { return .grok(.grok43) }
            if Self.isUnsupportedLegacyModel(provider: provider, model: model) {
                throw PeekabooError.invalidInput("Unsupported Grok model: \(model)")
            }
            if let parsed = LanguageModel.parse(from: model), case .grok = parsed {
                return parsed
            }
            return .grok(.custom(model))
        case "ollama":
            guard let model else { return .ollama(.llava) }
            return .ollama(.custom(model))
        default:
            throw PeekabooError.invalidInput("Unknown provider type: \(provider)")
        }
    }

    private static func isUnsupportedLegacyModel(provider: String, model: String) -> Bool {
        let normalized = model.lowercased()
        let compact = normalized.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ".", with: "")

        if provider == "openai",
           normalized.hasPrefix("gpt-4") || compact.hasPrefix("gpt4") ||
           normalized.hasPrefix("gpt-3") || compact.hasPrefix("gpt3") ||
           normalized.hasPrefix("o3") || normalized.hasPrefix("o4")
        {
            return true
        }

        if provider == "anthropic", normalized.hasPrefix("claude-3") || compact.hasPrefix("claude3") {
            return true
        }

        if provider == "grok" || provider == "xai",
           normalized.contains("grok-4.20-multi-agent") ||
           normalized.contains("grok-4-20-multi-agent") ||
           compact.contains("grok420multiagent")
        {
            return true
        }

        return false
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        self.isEmpty ? nil : self
    }
}
