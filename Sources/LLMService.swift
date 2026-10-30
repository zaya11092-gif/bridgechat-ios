import Foundation

/// OpenAI-compatible chat client: streaming completions + model listing.
struct LLMService {
    let config: ProviderConfig

    private func makeRequest(path: String, body: Data?) -> URLRequest {
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = URL(string: base + path)!
        var req = URLRequest(url: url, timeoutInterval: 300)
        req.httpMethod = body == nil ? "GET" : "POST"
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    /// GET {base}/models -> sorted model ids.
    func fetchModels() async throws -> [String] {
        let (data, resp) = try await URLSession.shared.data(for: makeRequest(path: "/models", body: nil))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppError.message("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1) listing models")
        }
        struct List: Decodable { struct Entry: Decodable { let id: String? }; let data: [Entry]? }
        let list = try JSONDecoder().decode(List.self, from: data)
        return Array(Set(list.data?.compactMap(\.id) ?? [])).sorted()
    }

    /// POST {base}/chat/completions with stream=true; calls onDelta per token.
    func streamChat(messages: [[String: Any]], onDelta: @escaping (String) -> Void) async throws {
        var body: [String: Any] = ["model": config.model, "messages": messages, "stream": true]
        body["stream_options"] = ["include_usage": false]
        let req = makeRequest(path: "/chat/completions",
                              body: try JSONSerialization.data(withJSONObject: body))
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            var err = ""
            for try await line in bytes.lines { err += line; if err.count > 600 { break } }
            throw AppError.message("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1): \(err)")
        }
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { return }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String, !content.isEmpty else { continue }
            onDelta(content)
        }
    }
}

/// Everything the AI sees besides the user's text: location, calendar,
/// bridge messages.
struct DeviceContextBuilder {
    static func build(location: String?, calendar: String?,
                      bridgeMessages: String?) -> String {
        var lines: [String] = []
        if let location, !location.isEmpty {
            lines.append("User's current location: \(location)")
        }
        if let calendar, !calendar.isEmpty {
            lines.append("User's upcoming calendar events:\n\(calendar)")
        }
        if let bridgeMessages, !bridgeMessages.isEmpty {
            lines.append("Recent messages from the user's iPhone backup:\n\(bridgeMessages)")
        }
        guard !lines.isEmpty else { return "" }
        return "\n\n[Device context]\n" + lines.joined(separator: "\n")
    }
}
