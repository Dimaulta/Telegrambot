import Vapor

final class SaluteSpeechRecognitionService {
    private struct RecognitionResponse: Decodable {
        let status: Int
        let result: RecognitionResult?
        let message: String?
        
        enum CodingKeys: String, CodingKey {
            case status
            case result
            case message
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decode(Int.self, forKey: .status)
            message = try container.decodeIfPresent(String.self, forKey: .message)
            
            if let objectResult = try? container.decode(RecognitionResult.self, forKey: .result) {
                result = objectResult
            } else if let arrayResult = try? container.decode([String].self, forKey: .result) {
                result = RecognitionResult(simpleArray: arrayResult)
            } else {
                result = nil
            }
        }
    }
    
    private struct RecognitionResult: Decodable {
        let text: String?
        let normalizedText: String?
        let chunks: [RecognitionChunk]?
        let alternatives: [RecognitionAlternative]?
        let items: [RecognitionItem]?
        let simpleTexts: [String]?
        
        struct RecognitionItem: Decodable {
            let text: String?
            let normalizedText: String?
        }
        
        init(text: String? = nil,
             normalizedText: String? = nil,
             chunks: [RecognitionChunk]? = nil,
             alternatives: [RecognitionAlternative]? = nil,
             items: [RecognitionItem]? = nil,
             simpleTexts: [String]? = nil) {
            self.text = text
            self.normalizedText = normalizedText
            self.chunks = chunks
            self.alternatives = alternatives
            self.items = items
            self.simpleTexts = simpleTexts
        }
        
        init(simpleArray: [String]) {
            self.init(simpleTexts: simpleArray)
        }
    }
    
    private struct RecognitionChunk: Decodable {
        let alternatives: [RecognitionAlternative]?
    }
    
    private struct RecognitionAlternative: Decodable {
        let text: String?
        let normalizedText: String?
    }
    
    private let app: Application
    private let authService: SaluteSpeechAuthService
    private let recognizeURI: URI
    
    init(app: Application, authService: SaluteSpeechAuthService) {
        self.app = app
        self.authService = authService
        let recognizeURLString = Environment.get("SALUTESPEECH_RECOGNIZE_URL") ?? "https://smartspeech.sber.ru/rest/v1/speech:recognize"
        self.recognizeURI = URI(string: recognizeURLString)
    }
    
    func recognize(audioData: Data, mimeType: String?, logger: Logger) async throws -> String {
        let token = try await authService.currentToken(logger: logger)
        
        var headers = HTTPHeaders()
        headers.add(name: .authorization, value: "Bearer \(token)")
        headers.add(name: .accept, value: "application/json")
        headers.add(name: .contentType, value: contentType(for: mimeType))
        
        var buffer = ByteBufferAllocator().buffer(capacity: audioData.count)
        buffer.writeBytes(audioData)
        
        let response = try await app.client.post(recognizeURI, headers: headers) { request in
            request.body = .init(buffer: buffer)
        }
        
        guard var responseBody = response.body,
              let data = responseBody.readData(length: responseBody.readableBytes) else {
            logger.error("SaluteSpeechRecognitionService: empty response body, status=\(response.status)")
            throw Abort(.internalServerError, reason: "Не получила ответ от SaluteSpeech при распознавании")
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let recognitionResponse: RecognitionResponse
        do {
            recognitionResponse = try decoder.decode(RecognitionResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? ""
            logger.error("SaluteSpeechRecognitionService: failed to decode response (\(raw)) error: \(error)")
            throw Abort(.internalServerError, reason: "Не удалось разобрать ответ от SaluteSpeech")
        }
        
        guard response.status == .ok, recognitionResponse.status == 200 else {
            let reason = recognitionResponse.message ?? response.status.reasonPhrase
            logger.error("SaluteSpeechRecognitionService: recognition failed, status=\(response.status), reason=\(reason)")
            throw Abort(.internalServerError, reason: "SaluteSpeech вернул ошибку распознавания: \(reason)")
        }
        
        if let text = recognitionResponse.result?.text,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return text
        }
        
        if let normalized = recognitionResponse.result?.normalizedText,
           normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return normalized
        }
        
        if let simpleTexts = recognitionResponse.result?.simpleTexts,
           simpleTexts.isEmpty == false {
            return simpleTexts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
                .joined(separator: " ")
        }
        
        if let chunks = recognitionResponse.result?.chunks {
            let alternatives = chunks.flatMap { $0.alternatives ?? [] }
            let texts = alternatives
                .compactMap { $0.text ?? $0.normalizedText }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
            if texts.isEmpty == false {
                return texts.joined(separator: " ")
            }
        }
        
        if let alternatives = recognitionResponse.result?.alternatives {
            let texts = alternatives
                .compactMap { $0.text ?? $0.normalizedText }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
            if texts.isEmpty == false {
                return texts.joined(separator: " ")
            }
        }
        
        throw Abort(.internalServerError, reason: "SaluteSpeech не прислал текст распознавания")
    }
    
    private func contentType(for mimeType: String?) -> String {
        guard var value = mimeType, value.isEmpty == false else {
            return "audio/ogg;codecs=opus"
        }
        if value.contains("ogg"), value.contains("codecs") == false {
            value.append(";codecs=opus")
        }
        return value
    }
}

extension SaluteSpeechRecognitionService: @unchecked Sendable {}

