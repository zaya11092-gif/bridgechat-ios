import Foundation

// User configuration, persisted to UserDefaults.
struct ProviderConfig: Codable, Equatable {
    var name: String = "Ollama"
    var baseURL: String = "http://127.0.0.1:11434/v1"
    var apiKey: String = ""
    var model: String = "qwen2.5:14b"
    var systemPrompt: String = "You are a helpful assistant."

    static let presets: [String: ProviderConfig] = [
        "Ollama": ProviderConfig(name: "Ollama", baseURL: "http://127.0.0.1:11434/v1",
                                 apiKey: "", model: "qwen2.5:14b"),
        "OpenAI": ProviderConfig(name: "OpenAI", baseURL: "https://api.openai.com/v1",
                                 apiKey: "", model: "gpt-4o-mini"),
        "z.ai": ProviderConfig(name: "z.ai", baseURL: "https://api.z.ai/api/paas/v4",
                               apiKey: "", model: "glm-4.6"),
        "Custom": ProviderConfig(name: "Custom", baseURL: "https://", apiKey: "", model: "")
    ]
}

struct AppSettings: Codable, Equatable {
    var provider: ProviderConfig = .init()
    var includeLocation: Bool = false
    var includeCalendar: Bool = false
    var bridgeURL: String = ""          // optional: http://192.168.1.169 (grok-bridge)
    var useBridgeMessages: Bool = false  // pull backup messages from the bridge
}

// A single chat turn.
struct ChatTurn: Identifiable, Equatable {
    var id = UUID()
    var role: Role
    var text: String
    var images: [String] = []   // data URLs (vision)
    var isStreaming = false

    enum Role: String { case system, user, assistant }

    /// OpenAI-style JSON payload for this turn.
    func payload() -> [String: Any] {
        if images.isEmpty {
            return ["role": role.rawValue, "content": text]
        }
        var parts: [[String: Any]] = [["type": "text", "text": text]]
        for img in images {
            parts.append(["type": "image_url", "image_url": ["url": img]])
        }
        return ["role": role.rawValue, "content": parts]
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { 
        if case .message(let m) = self { return m }
        return nil
    }
}
