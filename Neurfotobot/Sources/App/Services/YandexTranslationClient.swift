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
        let url = URI(string: "https://translate.api.cloud.yandex.net/translate/v2/translate")
        
        struct TranslationRequest: Encodable {
            let sourceLanguageCode: String
            let targetLanguageCode: String
            let texts: [String]
            let format: String
        }
        
        let payload = TranslationRequest(
            sourceLanguageCode: "ru",
            targetLanguageCode: "en",
            texts: [text],
            format: "PLAIN_TEXT"
        )
        
        let data = try JSONEncoder().encode(payload)
        var buffer = allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)

        var request = ClientRequest(method: .POST, url: url)
        request.headers.add(name: "Authorization", value: "Api-Key \(apiKey)")
        request.headers.add(name: .contentType, value: "application/json")
        request.body = buffer

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
    }
}

private struct TranslationResponse: Decodable {
    struct Translation: Decodable {
        let text: String
        let detectedLanguageCode: String?
    }
    let translations: [Translation]
}

