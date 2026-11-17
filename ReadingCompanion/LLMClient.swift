import Foundation

struct LLMConfig {
    var baseURL: String = "https://opencode.ai/zen/go/v1"
    var model: String = "deepseek-v4.1-flash"
    var apiKey: String = ""
}

final class LLMClient {
    private var task: Task<Void, Never>?
    private let sessionID: String

    init() {
        if let saved = UserDefaults.standard.string(forKey: "opencode_session_id"), !saved.isEmpty {
            sessionID = saved
        } else {
            let generated = UUID().uuidString
            UserDefaults.standard.set(generated, forKey: "opencode_session_id")
            sessionID = generated
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func stream(
        turns: [ChatTurn],
        context: ReadingContext,
        config: LLMConfig,
        onDelta: @escaping (String) -> Void,
        onDone: @escaping (Result<Void, Error>) -> Void
    ) {
        cancel()
        guard !config.apiKey.isEmpty else {
            onDone(.failure(NSError(domain: "LLM", code: 401,
                                    userInfo: [NSLocalizedDescriptionKey: "请先在设置里填写 OpenCode Go API Key"])))
            return
        }
        guard let url = URL(string: config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else {
            onDone(.failure(NSError(domain: "LLM", code: 400,
                                    userInfo: [NSLocalizedDescriptionKey: "Base URL 不正确"])))
            return
        }

        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt(context: context)]
        ]
        for turn in turns.suffix(8) {
            messages.append(["role": turn.role.rawValue, "content": turn.text])
        }

        let body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "stream": true,
            "temperature": 0.7,
            "max_tokens": 600
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(sessionID, forHTTPHeaderField: "x-opencode-session")
        request.setValue("ReadingCompanion/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        task = Task {
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw NSError(domain: "LLM", code: 0,
                                  userInfo: [NSLocalizedDescriptionKey: "没有响应"])
                }
                guard (200..<300).contains(http.statusCode) else {
                    var detail = ""
                    for try await line in bytes.lines {
                        detail += line
                        if detail.count > 800 { break }
                    }
                    throw NSError(domain: "LLM", code: http.statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: "API \(http.statusCode): \(detail)"])
                }
                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }
                    guard let data = payload.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choices = json["choices"] as? [[String: Any]],
                          let delta = choices.first?["delta"] as? [String: Any],
                          let content = delta["content"] as? String,
                          !content.isEmpty else {
                        continue
                    }
                    await MainActor.run { onDelta(content) }
                }
                await MainActor.run { onDone(.success(())) }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run { onDone(.failure(error)) }
            }
        }
    }

    private func systemPrompt(context: ReadingContext) -> String {
        let text = String(context.text.prefix(6000))
        return """
        你是用户的读书陪读，中文口语化，回答简短、具体，像坐在旁边聊天。
        只基于下面“当前阅读上下文”回答；不要剧透用户还没读到的内容。
        如果用户问的问题超出上下文，先说明你只看到当前页，再给一般性解释。
        必要时用一个问题反问，帮用户想深一点。

        当前书：\(context.book)
        当前章节：\(context.chapter)
        当前页：\(context.page)
        阅读进度：\(String(format: "%.1f", context.progress))%

        当前阅读上下文：
        \(text)
        """
    }
}
