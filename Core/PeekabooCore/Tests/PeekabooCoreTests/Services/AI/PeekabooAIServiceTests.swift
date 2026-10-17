//
//  PeekabooAIServiceTests.swift
//  PeekabooCore
//

import AppKit
import Foundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore
@testable import PeekabooVisualizer

struct PeekabooAIServiceTests {
    @Test
    @MainActor
    func `Initialize AI service`() {
        let service = PeekabooAIService()
        #expect(service != nil)
    }

    @Test
    @MainActor
    func `List available models`() {
        let service = PeekabooAIService()
        let models = service.availableModels()

        #expect(!models.isEmpty)
        #expect(models == [.openai(.gpt56Sol), .anthropic(.opus5)])
    }

    @Test
    @MainActor
    func `Respects configured provider default`() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let configPath = tempDir.appendingPathComponent("config.json")
        try """
        {
          "aiProviders": { "providers": "anthropic/claude-opus-4-7" }
        }
        """.write(to: configPath, atomically: true, encoding: .utf8)

        // Point configuration manager at the temporary config and reload.
        setenv("PEEKABOO_CONFIG_DIR", tempDir.path, 1)
        defer {
            unsetenv("PEEKABOO_CONFIG_DIR")
            ConfigurationManager.shared.resetForTesting()
            try? FileManager.default.removeItem(at: tempDir)
        }

        ConfigurationManager.shared.resetForTesting()
        _ = ConfigurationManager.shared.loadConfiguration()

        let service = PeekabooAIService()
        #expect(service.resolvedDefaultModel == .anthropic(.opus47))
        #expect(service.availableModels() == [.anthropic(.opus47)])
    }

    @Test
    @MainActor
    func `Uses provider list ordering for default model`() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let configPath = tempDir.appendingPathComponent("config.json")
        try """
        {
          "aiProviders": { "providers": "anthropic/claude-opus-4-7,openai/gpt-5.5" }
        }
        """.write(to: configPath, atomically: true, encoding: .utf8)

        setenv("PEEKABOO_CONFIG_DIR", tempDir.path, 1)
        defer {
            unsetenv("PEEKABOO_CONFIG_DIR")
            ConfigurationManager.shared.resetForTesting()
            try? FileManager.default.removeItem(at: tempDir)
        }

        ConfigurationManager.shared.resetForTesting()
        _ = ConfigurationManager.shared.loadConfiguration()

        let service = PeekabooAIService()
        #expect(service.availableModels() == [.anthropic(.opus47), .openai(.gpt55)])
        #expect(service.resolvedDefaultModel == .anthropic(.opus47))
    }

    @Test
    @MainActor
    func `Uses configured vision model for nil-model analysis`() throws {
        try self.withIsolatedAIService(
            configJSON: """
            {
              "aiProviders": { "providers": "openai/gpt-5.6,anthropic/claude-opus-5" },
              "agent": { "visionModel": "anthropic/claude-opus-5" }
            }
            """) { service in
                #expect(service.resolvedDefaultVisionModel == .openai(.gpt56Sol))
                let analysisModel = try service.resolvedAnalysisVisionModel()
                #expect(analysisModel == .anthropic(.opus5))
            }
    }

    @Test
    @MainActor
    func `Nil-model analysis uses the first vision model without a vision override`() throws {
        try self.withIsolatedAIService(
            configJSON: """
            {
              "aiProviders": { "providers": "openai/gpt-5.6,anthropic/claude-opus-5" }
            }
            """) { service in
                #expect(service.resolvedDefaultVisionModel == .openai(.gpt56Sol))
                let analysisModel = try service.resolvedAnalysisVisionModel()
                #expect(analysisModel == .openai(.gpt56Sol))
            }
    }

    @Test
    @MainActor
    func `Parses Ollama provider/model entries without defaulting to Llama`() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let configPath = tempDir.appendingPathComponent("config.json")
        try """
        {
          "aiProviders": { "providers": "ollama/qwen2.5vl:latest" }
        }
        """.write(to: configPath, atomically: true, encoding: .utf8)

        setenv("PEEKABOO_CONFIG_DIR", tempDir.path, 1)
        defer {
            unsetenv("PEEKABOO_CONFIG_DIR")
            ConfigurationManager.shared.resetForTesting()
            try? FileManager.default.removeItem(at: tempDir)
        }

        ConfigurationManager.shared.resetForTesting()
        _ = ConfigurationManager.shared.loadConfiguration()

        let service = PeekabooAIService()
        #expect(service.resolvedDefaultModel == .ollama(.custom("qwen2.5vl:latest")))
        #expect(service.availableModels() == [.ollama(.custom("qwen2.5vl:latest"))])
    }

    @Test
    @MainActor
    func `Environment provider list overrides config for Ollama models`() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let configPath = tempDir.appendingPathComponent("config.json")
        try """
        {
          "aiProviders": { "providers": "anthropic/claude-opus-4-7" }
        }
        """.write(to: configPath, atomically: true, encoding: .utf8)

        setenv("PEEKABOO_CONFIG_DIR", tempDir.path, 1)
        setenv("PEEKABOO_AI_PROVIDERS", "ollama/qwen2.5vl:latest", 1)
        defer {
            unsetenv("PEEKABOO_AI_PROVIDERS")
            unsetenv("PEEKABOO_CONFIG_DIR")
            ConfigurationManager.shared.resetForTesting()
            try? FileManager.default.removeItem(at: tempDir)
        }

        ConfigurationManager.shared.resetForTesting()
        _ = ConfigurationManager.shared.loadConfiguration()

        let service = PeekabooAIService()
        #expect(service.resolvedDefaultModel == .ollama(.custom("qwen2.5vl:latest")))
        #expect(service.availableModels() == [.ollama(.custom("qwen2.5vl:latest"))])
    }

    @Test
    @MainActor
    func `Automatically loads configuration when resolving providers`() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let configPath = tempDir.appendingPathComponent("config.json")
        try """
        {
          "aiProviders": { "providers": "anthropic/claude-opus-4-7" }
        }
        """.write(to: configPath, atomically: true, encoding: .utf8)

        setenv("PEEKABOO_CONFIG_DIR", tempDir.path, 1)
        defer {
            unsetenv("PEEKABOO_CONFIG_DIR")
            ConfigurationManager.shared.resetForTesting()
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Intentionally do NOT call loadConfiguration to mirror CLI startup.
        ConfigurationManager.shared.resetForTesting()

        let service = PeekabooAIService()
        #expect(service.availableModels() == [.anthropic(.opus47)])
        #expect(service.resolvedDefaultModel == .anthropic(.opus47))
    }

    @Test
    @MainActor
    func `Auth-only Anthropic fallback remains zero-retention compatible`() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        setenv("PEEKABOO_CONFIG_DIR", tempDir.path, 1)
        setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", "1", 1)
        setenv("ANTHROPIC_API_KEY", "key", 1)
        unsetenv("OPENAI_API_KEY")
        defer {
            unsetenv("PEEKABOO_CONFIG_DIR")
            unsetenv("PEEKABOO_CONFIG_DISABLE_MIGRATION")
            unsetenv("ANTHROPIC_API_KEY")
            ConfigurationManager.shared.resetForTesting()
            try? FileManager.default.removeItem(at: tempDir)
        }

        ConfigurationManager.shared.resetForTesting()
        _ = ConfigurationManager.shared.loadConfiguration()

        let service = PeekabooAIService()
        #expect(service.resolvedDefaultModel == .anthropic(.opus48))
        #expect(service.availableModels() == [.anthropic(.opus48)])
    }

    @Test
    @MainActor
    func `Saved current provider generation selects Opus 5`() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try """
        {
          "aiProviders": { "providers": "openai/gpt-5.6,anthropic/claude-opus-5" }
        }
        """.write(
            to: tempDir.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8)

        setenv("PEEKABOO_CONFIG_DIR", tempDir.path, 1)
        setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", "1", 1)
        setenv("ANTHROPIC_API_KEY", "key", 1)
        unsetenv("OPENAI_API_KEY")
        defer {
            unsetenv("PEEKABOO_CONFIG_DIR")
            unsetenv("PEEKABOO_CONFIG_DISABLE_MIGRATION")
            unsetenv("ANTHROPIC_API_KEY")
            ConfigurationManager.shared.resetForTesting()
            try? FileManager.default.removeItem(at: tempDir)
        }

        ConfigurationManager.shared.resetForTesting()
        _ = ConfigurationManager.shared.loadConfiguration()

        let service = PeekabooAIService()
        #expect(service.resolvedDefaultModel == .anthropic(.opus5))
        #expect(service.availableModels() == [.anthropic(.opus5)])
    }

    @Test
    @MainActor
    func `Falls back to Gemini when only Gemini key is present`() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        setenv("PEEKABOO_CONFIG_DIR", tempDir.path, 1)
        setenv("GEMINI_API_KEY", "key", 1)
        unsetenv("PEEKABOO_AI_PROVIDERS")
        unsetenv("OPENAI_API_KEY")
        unsetenv("ANTHROPIC_API_KEY")
        unsetenv("MINIMAX_API_KEY")
        defer {
            unsetenv("PEEKABOO_CONFIG_DIR")
            unsetenv("GEMINI_API_KEY")
            ConfigurationManager.shared.resetForTesting()
            try? FileManager.default.removeItem(at: tempDir)
        }

        ConfigurationManager.shared.resetForTesting()
        _ = ConfigurationManager.shared.loadConfiguration()

        let service = PeekabooAIService()
        #expect(service.resolvedDefaultModel == .google(.gemini35Flash))
        #expect(service.availableModels() == [.google(.gemini35Flash)])
    }

    @Test
    @MainActor
    func `Falls back to MiniMax when only MiniMax key is present`() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        setenv("PEEKABOO_CONFIG_DIR", tempDir.path, 1)
        setenv("MINIMAX_API_KEY", "key", 1)
        unsetenv("PEEKABOO_AI_PROVIDERS")
        unsetenv("OPENAI_API_KEY")
        unsetenv("ANTHROPIC_API_KEY")
        unsetenv("GEMINI_API_KEY")
        unsetenv("GOOGLE_API_KEY")
        defer {
            unsetenv("PEEKABOO_CONFIG_DIR")
            unsetenv("MINIMAX_API_KEY")
            ConfigurationManager.shared.resetForTesting()
            try? FileManager.default.removeItem(at: tempDir)
        }

        ConfigurationManager.shared.resetForTesting()
        _ = ConfigurationManager.shared.loadConfiguration()

        let service = PeekabooAIService()
        #expect(service.resolvedDefaultModel == .minimax(.m27))
        #expect(service.availableModels() == [.minimax(.m27)])
    }

    @Test
    @MainActor
    func `Falls back to OpenAI when no config or keys present`() {
        unsetenv("PEEKABOO_CONFIG_DIR")
        unsetenv("OPENAI_API_KEY")
        unsetenv("ANTHROPIC_API_KEY")
        ConfigurationManager.shared.resetForTesting()
        _ = ConfigurationManager.shared.loadConfiguration()

        let service = PeekabooAIService()
        #expect(service.resolvedDefaultModel == .openai(.gpt56Sol))
        #expect(service.availableModels().first == .openai(.gpt56Sol))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil, "OPENAI_API_KEY not configured"))
    @MainActor
    func `Generate text with default model`() async throws {
        let service = PeekabooAIService()

        let result = try await service.generateText(prompt: "Say 'Hello test' and nothing else")
        #expect(result.lowercased().contains("hello"))
        #expect(result.lowercased().contains("test"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil, "OPENAI_API_KEY not configured"))
    @MainActor
    func `Analyze image data`() async throws {
        let service = PeekabooAIService()

        // Create a simple test image (1x1 red pixel)
        let imageData = self.createTestImageData()

        let result = try await service.analyzeImage(
            imageData: imageData,
            question: "What color is this image? Answer with just the color name.")

        #expect(!result.isEmpty)
        // The AI should recognize it's a red image
        #expect(result.lowercased().contains("red") || result.lowercased().contains("color"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil, "OPENAI_API_KEY not configured"))
    @MainActor
    func `Analyze image file`() async throws {
        let service = PeekabooAIService()

        // Create a temporary test image file
        let tempDir = FileManager.default.temporaryDirectory
        let imagePath = tempDir.appendingPathComponent("test_image_\(UUID().uuidString).png").path

        let imageData = self.createTestImageData()
        try imageData.write(to: URL(fileURLWithPath: imagePath))

        defer {
            try? FileManager.default.removeItem(atPath: imagePath)
        }

        let result = try await service.analyzeImageFile(
            at: imagePath,
            question: "Is there an image? Answer yes or no.")

        #expect(!result.isEmpty)
        #expect(result.lowercased().contains("yes") || result.lowercased().contains("image"))
    }

    @Test
    @MainActor
    func `Image file URL expands leading tilde only`() {
        let homePath = PeekabooAIService.imageFileURL(for: "~/Desktop/image.png").path
        #expect(homePath == NSString(string: "~/Desktop/image.png").expandingTildeInPath)

        let embeddedTildePath = "/tmp/peekaboo-image~literal.png"
        #expect(PeekabooAIService.imageFileURL(for: embeddedTildePath).path == embeddedTildePath)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil, "OPENAI_API_KEY not configured"))
    @MainActor
    func `Use custom model for generation`() async throws {
        let service = PeekabooAIService()

        let result = try await service.generateText(
            prompt: "Say 'Model test' and nothing else",
            model: .openai(.gpt55))

        #expect(result.lowercased().contains("model"))
        #expect(result.lowercased().contains("test"))
    }

    @MainActor
    private func withIsolatedAIService(
        configJSON: String,
        _ body: @MainActor (PeekabooAIService) throws -> Void) throws
    {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let configPath = tempDir.appendingPathComponent("config.json")
        try configJSON.write(to: configPath, atomically: true, encoding: .utf8)

        let isolatedKeys = [
            "PEEKABOO_AI_PROVIDERS",
            "OPENAI_API_KEY",
            "OPENAI_ACCESS_TOKEN",
            "OPENAI_REFRESH_TOKEN",
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_ACCESS_TOKEN",
            "ANTHROPIC_REFRESH_TOKEN",
            "GEMINI_API_KEY",
            "GOOGLE_API_KEY",
            "X_AI_API_KEY",
            "XAI_API_KEY",
            "GROK_API_KEY",
            "MINIMAX_API_KEY",
            "MINIMAX_CN_API_KEY",
            "MOONSHOT_API_KEY",
            "KIMI_API_KEY",
            "OPENROUTER_API_KEY",
        ]
        let savedKeys = isolatedKeys.map { key in
            (key, getenv(key).map { String(cString: $0) })
        }
        let savedConfigDir = getenv("PEEKABOO_CONFIG_DIR").map { String(cString: $0) }
        let savedDisableMigration = getenv("PEEKABOO_CONFIG_DISABLE_MIGRATION").map { String(cString: $0) }

        setenv("PEEKABOO_CONFIG_DIR", tempDir.path, 1)
        setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", "1", 1)
        for key in isolatedKeys {
            unsetenv(key)
        }
        defer {
            if let savedConfigDir {
                setenv("PEEKABOO_CONFIG_DIR", savedConfigDir, 1)
            } else {
                unsetenv("PEEKABOO_CONFIG_DIR")
            }
            if let savedDisableMigration {
                setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", savedDisableMigration, 1)
            } else {
                unsetenv("PEEKABOO_CONFIG_DISABLE_MIGRATION")
            }
            for (key, value) in savedKeys {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
            ConfigurationManager.shared.resetForTesting()
            try? FileManager.default.removeItem(at: tempDir)
        }

        ConfigurationManager.shared.resetForTesting()
        _ = ConfigurationManager.shared.loadConfiguration()
        try body(PeekabooAIService())
    }

    /// Helper function to create test image data
    private func createTestImageData() -> Data {
        // Create a simple 1x1 red pixel PNG
        let width = 1
        let height = 1
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        // Set red pixel (RGBA)
        pixels[0] = 255 // R
        pixels[1] = 0 // G
        pixels[2] = 0 // B
        pixels[3] = 255 // A

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue)
        else {
            return Data()
        }

        guard let cgImage = context.makeImage() else {
            return Data()
        }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:])
        else {
            return Data()
        }

        return pngData
    }
}
