import Vapor
import Foundation

struct YandexTranslationClient {
    private let apiKey: String
    private let client: Client
    private let allocator = ByteBufferAllocator()

    init(request: Request) throws {
        guard let apiKey = Environment.get("YANDEX_TRANSLATE_API_KEY"), !apiKey.isEmpty else {
            throw Abort(.internalServerError, reason: "YANDEX_TRANSLATE_API_KEY is not set")
        }
        self.apiKey = apiKey
        self.client = request.client
    }

    func translateToEnglish(_ text: String) async throws -> String {
        // Проверяем, что текст не пустой
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "Translation text is empty")
        }
        
        let url = URI(string: "https://translate.api.cloud.yandex.net/translate/v2/translate")
        
        struct TranslationRequest: Encodable {
            let targetLanguageCode: String
            let texts: [String]
            let folderId: String?
        }
        
        let payload = TranslationRequest(
            targetLanguageCode: "en",
            texts: [text],
            folderId: Environment.get("YANDEX_CLOUD_FOLDER_ID") // Optional, if needed
        )
        
        let data = try JSONEncoder().encode(payload)
        var buffer = allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)

        var request = ClientRequest(method: .POST, url: url)
        request.headers.add(name: "Authorization", value: "Api-Key \(apiKey)")
        request.headers.add(name: .contentType, value: "application/json")
        request.body = buffer

        // Retry логика: пытаемся 2 раза с задержкой
        var lastError: Error?
        for attempt in 1...2 {
            do {
                let response = try await client.send(request)
                
                guard response.status == .ok else {
                    let errorBody = response.body.flatMap { buffer -> String in
                        var copy = buffer
                        return copy.readString(length: copy.readableBytes) ?? ""
                    } ?? ""
                    throw Abort(.badRequest, reason: "Yandex translation error: \(response.status) - \(errorBody)")
                }

                guard let body = response.body else {
                    throw Abort(.badRequest, reason: "Yandex translation response is empty")
                }

                let responseData = body.getData(at: 0, length: body.readableBytes) ?? Data()
                let decoded = try JSONDecoder().decode(TranslationResponse.self, from: responseData)
                
                guard let translatedText = decoded.translations.first?.text else {
                    throw Abort(.badRequest, reason: "Yandex translation response has no text")
                }
                
                return translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                lastError = error
                if attempt < 2 {
                    // Ждём 2 секунды перед повторной попыткой
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
        
        // Если все попытки провалились, пробрасываем последнюю ошибку
        throw lastError!
    }
}

private struct TranslationResponse: Decodable {
    struct Translation: Decodable {
        let text: String
        let detectedLanguageCode: String?
    }
    let translations: [Translation]
}

