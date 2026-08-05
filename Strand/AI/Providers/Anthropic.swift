import Foundation

struct AnthropicClient: AIProviderClient {

    func send(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession
    ) async throws -> String {
        var wire: [[String: Any]] = []
        for m in messages { wire.append(["role": m.role.rawValue, "content": m.content]) }

        // Anthropic: system prompt is a top-level field, not a message role.
        // max_tokens covers thinking + response text together on the Claude 5 series (which runs
        // adaptive thinking by default), so 900 would let thinking starve the visible answer.
        let body: [String: Any] = [
            "model": model,
            // #1074: 900 truncated detailed coaching replies mid-sentence; 4096 lets a full multi-section
            // reply complete (a cap, not a target — the system prompt keeps it short). Matches the others.
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": wire
        ]

        var req = URLRequest(url: AIProvider.anthropic.endpoint)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await performRequest(req, session: session)
        guard let content = json["content"] as? [[String: Any]] else {
            throw emptyReplyError(json)   // #1074: surface the provider's real error if the 200 body has one
        }
        // Claude 5-series models run adaptive thinking by default: `content` then LEADS with one or
        // more `thinking` blocks before the `text` block(s). Reading `content.first` blindly broke
        // on those models ("couldn't read the provider's reply") — join every text block instead.
        // #1074 stays honest here: an empty join goes through `emptyReplyError` too, so a 200 body
        // carrying a provider error message surfaces THAT rather than a bare decode failure.
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw emptyReplyError(json) }
        return text
    }

    func fetchModels(key: String, session: URLSession) async throws -> [String] {
        var req = URLRequest(url: AIProvider.anthropic.modelsEndpoint)
        req.httpMethod = "GET"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        return parseModels(try await performRequest(req, session: session))
    }

    /// Pure: unwrap the `/models` body into ids (Anthropic keeps all non-empty). No network — unit-tested.
    func parseModels(_ json: [String: Any]) -> [String] {
        guard let list = json["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return id
        }
    }
}
