import Vapor
import Foundation

struct OpenAIStyleService {
    private let apiKey: String
    private let client: Client
    private let logger: Logger
    
    init(request: Request) throws {
        guard let apiKey = Environment.get("OPENAI_API_KEY"), !apiKey.isEmpty else {
            throw Abort(.internalServerError, reason: "OPENAI_API_KEY is not set")
        }
        self.apiKey = apiKey
        self.client = request.client
        self.logger = request.logger
    }
    
    /// Анализирует стиль написания постов и создает профиль стиля
    func analyzeStyle(posts: [String]) async throws -> String {
        let postsText = posts.enumerated().map { "Пост \($0.offset + 1):\n\($0.element)" }.joined(separator: "\n\n---\n\n")
        
        let prompt = """
Проанализируй стиль написания следующих постов из Telegram канала и создай детальное описание стиля автора.

Посты для анализа:
\(postsText)

Создай описание стиля, которое включает:
1. Длину предложений (короткие/средние/длинные)
2. Использование эмодзи и их частота
3. Тон общения (формальный/неформальный/дружелюбный/строгий)
4. Структуру текста (абзацы, списки, вопросы)
5. Устойчивые слова и фразы, которые часто используются
6. Особенности пунктуации
7. Любые другие характерные черты стиля

Ответ должен быть на русском языке и представлять собой детальное описание стиля, которое можно использовать для генерации новых постов в таком же стиле.
"""
        
        let url = URI(string: "https://api.openai.com/v1/chat/completions")
        var request = ClientRequest(method: .POST, url: url)
        request.headers.add(name: .authorization, value: "Bearer \(apiKey)")
        request.headers.add(name: .contentType, value: "application/json")
        
        let payload = OpenAIRequest(
            model: "gpt-4o-mini",
            messages: [
                OpenAIMessage(role: "system", content: "Ты эксперт по анализу стиля письма. Твоя задача - создать детальное описание стиля автора на основе предоставленных примеров."),
                OpenAIMessage(role: "user", content: prompt)
            ],
            temperature: 0.3
        )
        
        request.body = try .init(data: JSONEncoder().encode(payload))
        
        logger.info("📤 Sending request to OpenAI API for style analysis")
        let response = try await client.send(request)
        
        // Логируем статус ответа
        logger.info("📥 OpenAI API response status: \(response.status)")
        
        guard response.status == .ok else {
            var errorBody = ""
            if let errorBuffer = response.body {
                errorBody = errorBuffer.getString(at: 0, length: min(errorBuffer.readableBytes, 1000)) ?? ""
            }
            logger.error("❌ OpenAI API error: status=\(response.status), body=\(errorBody)")
            throw Abort(.badRequest, reason: "OpenAI API error: \(response.status) - \(errorBody)")
        }
        
        guard var body = response.body else {
            logger.error("❌ OpenAI API response body is nil")
            throw Abort(.badRequest, reason: "OpenAI API response body is nil")
        }
        
        let readableBytes = body.readableBytes
        logger.info("📥 OpenAI API response body size: \(readableBytes) bytes")
        
        guard readableBytes > 0 else {
            logger.error("❌ OpenAI API response body is empty")
            throw Abort(.badRequest, reason: "OpenAI API response body is empty")
        }
        
        // Используем readData вместо getData для корректного чтения тела ответа
        guard let data = body.readData(length: readableBytes) else {
            logger.error("❌ OpenAI API response data is empty after extraction")
            throw Abort(.badRequest, reason: "OpenAI API response data is empty")
        }
        
        // Логируем первые 500 символов ответа для отладки
        if let responseString = String(data: data, encoding: .utf8) {
            logger.info("📥 OpenAI API response preview: \(responseString.prefix(500))")
        }
        
        let decoded: OpenAIResponse
        do {
            decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        } catch {
            logger.error("❌ Failed to decode OpenAI response: \(error)")
            if let responseString = String(data: data, encoding: .utf8) {
                logger.error("📥 Full response body: \(responseString)")
            }
            throw Abort(.badRequest, reason: "Failed to decode OpenAI response: \(error.localizedDescription)")
        }
        
        guard let choice = decoded.choices.first,
              let content = choice.message.content else {
            logger.error("❌ OpenAI response has no content in choices")
            throw Abort(.badRequest, reason: "OpenAI response has no content")
        }
        
        return content
    }
    
    /// Генерирует пост на основе темы и профиля стиля
    func generatePost(topic: String, styleProfile: String) async throws -> String {
        let prompt = """
Используя следующий профиль стиля автора, напиши пост для Telegram канала на заданную тему.

Профиль стиля автора:
\(styleProfile)

Тема для поста:
\(topic)

ВАЖНО:
- Напиши пост ТОЛЬКО в точном соответствии со стилем автора
- НЕ добавляй дефолтные фразы типа "Привет друзья", "Добро пожаловать" и т.п., если их нет в стиле автора
- Используй ТОЧНО те же особенности: длину предложений, эмодзи (только если они есть в стиле автора), тон, структуру и устойчивые слова
- Избегай эмодзи. Даже если они встречаются в стиле автора, используй максимум один и только если без него текст теряет смысл
- Начни пост сразу с содержания, без приветствий, если их нет в стиле автора
- Не используй длинные тире — или –. Всегда заменяй их на обычный дефис "-"
- Каждое предложение начинай с заглавной буквы
- В пунктах списков не ставь точку в конце строки
- Последнее предложение оставь без точки, вопросительного или восклицательного знака — просто закончи текст
- Пост должен быть КОРОТКИМ: максимум 800-900 символов (для возможности добавления фото в Telegram)
- Генерируй ТОЛЬКО текст публикации, без дополнительных комментариев
"""
        
        let url = URI(string: "https://api.openai.com/v1/chat/completions")
        var request = ClientRequest(method: .POST, url: url)
        request.headers.add(name: .authorization, value: "Bearer \(apiKey)")
        request.headers.add(name: .contentType, value: "application/json")
        
        let payload = OpenAIRequest(
            model: "gpt-4o-mini",
            messages: [
                OpenAIMessage(role: "system", content: "Ты помощник, который пишет посты для Telegram каналов в стиле конкретного автора. Твоя задача - точно воспроизвести стиль автора."),
                OpenAIMessage(role: "user", content: prompt)
            ],
            temperature: 0.7
        )
        
        request.body = try .init(data: JSONEncoder().encode(payload))
        
        logger.info("📤 Sending request to OpenAI API for post generation")
        let response = try await client.send(request)
        
        // Логируем статус ответа
        logger.info("📥 OpenAI API response status: \(response.status)")
        
        guard response.status == .ok else {
            var errorBody = ""
            if let errorBuffer = response.body {
                errorBody = errorBuffer.getString(at: 0, length: min(errorBuffer.readableBytes, 1000)) ?? ""
            }
            logger.error("❌ OpenAI API error: status=\(response.status), body=\(errorBody)")
            throw Abort(.badRequest, reason: "OpenAI API error: \(response.status) - \(errorBody)")
        }
        
        guard var body = response.body else {
            logger.error("❌ OpenAI API response body is nil")
            throw Abort(.badRequest, reason: "OpenAI API response body is nil")
        }
        
        let readableBytes = body.readableBytes
        logger.info("📥 OpenAI API response body size: \(readableBytes) bytes")
        
        guard readableBytes > 0 else {
            logger.error("❌ OpenAI API response body is empty")
            throw Abort(.badRequest, reason: "OpenAI API response body is empty")
        }
        
        // Используем readData вместо getData для корректного чтения тела ответа
        guard let data = body.readData(length: readableBytes) else {
            logger.error("❌ OpenAI API response data is empty after extraction")
            throw Abort(.badRequest, reason: "OpenAI API response data is empty")
        }
        
        // Логируем первые 500 символов ответа для отладки
        if let responseString = String(data: data, encoding: .utf8) {
            logger.info("📥 OpenAI API response preview: \(responseString.prefix(500))")
        }
        
        let decoded: OpenAIResponse
        do {
            decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        } catch {
            logger.error("❌ Failed to decode OpenAI response: \(error)")
            if let responseString = String(data: data, encoding: .utf8) {
                logger.error("📥 Full response body: \(responseString)")
            }
            throw Abort(.badRequest, reason: "Failed to decode OpenAI response: \(error.localizedDescription)")
        }
        
        guard let choice = decoded.choices.first,
              let content = choice.message.content else {
            logger.error("❌ OpenAI response has no content in choices")
            throw Abort(.badRequest, reason: "OpenAI response has no content")
        }
        
        return sanitizeGeneratedPost(content)
    }
}

private func sanitizeGeneratedPost(_ text: String) -> String {
    var cleaned = text
        .replacingOccurrences(of: "—", with: "-")
        .replacingOccurrences(of: "–", with: "-")
    
    let withoutEmoji = cleaned.filter { !$0.isEmoji }
    cleaned = String(withoutEmoji).trimmingCharacters(in: .whitespacesAndNewlines)
    
    while let last = cleaned.last, ".!?…".contains(last) {
        cleaned.removeLast()
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    return cleaned
}

private extension Character {
    var isEmoji: Bool {
        return unicodeScalars.contains { $0.properties.isEmoji && ($0.properties.isEmojiPresentation || $0.properties.generalCategory == .otherSymbol) }
    }
}

private struct OpenAIRequest: Encodable {
    let model: String
    let messages: [OpenAIMessage]
    let temperature: Double
}

private struct OpenAIMessage: Encodable {
    let role: String
    let content: String
}

private struct OpenAIResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let role: String
            let content: String?
        }
        let message: Message
    }
    let choices: [Choice]
}

