import Vapor

struct VideoGenerationResult {
    let videoURL: String
    let status: String?
    let requestId: String?
    let caption: String?
}

final class VideoGenerationService {
    private let apiKey: String?

    init() {
        self.apiKey = Environment.get("SORANOWBOT_API_KEY")
    }

    func generateVideo(prompt: String, on req: Request) async throws -> VideoGenerationResult {
        struct RequestPayload: Content {
            let prompt: String
        }

        struct ResponsePayload: Decodable {
            let videoUrl: String?
            let status: String?
            let requestId: String?
            let caption: String?
            let message: String?
        }

        guard let endpointString = Environment.get("SORANOWBOT_API_URL"),
              endpointString.isEmpty == false else {
            throw Abort(.internalServerError, reason: "SORANOWBOT_API_URL is not configured")
        }

        let endpoint = URI(string: endpointString)

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")
        if let apiKey, apiKey.isEmpty == false {
            headers.add(name: .authorization, value: "Bearer \(apiKey)")
        }

        let payload = RequestPayload(prompt: prompt)
        let response = try await req.client.post(endpoint, headers: headers) { request in
            let data = try JSONEncoder().encode(payload)
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            request.body = .init(buffer: buffer)
        }

        guard (200...299).contains(Int(response.status.code)) else {
            req.logger.error("VideoGenerationService: API returned status \(response.status.code)")
            throw Abort(.internalServerError, reason: "Внешний сервис вернул ошибку \(response.status.code)")
        }

        guard var responseBody = response.body,
              let data = responseBody.readData(length: responseBody.readableBytes) else {
            throw Abort(.internalServerError, reason: "Внешний сервис не прислал тело ответа")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(ResponsePayload.self, from: data)

        if let url = decoded.videoUrl, url.isEmpty == false {
            return VideoGenerationResult(
                videoURL: url,
                status: decoded.status,
                requestId: decoded.requestId,
                caption: decoded.caption
            )
        }

        let reason = decoded.message ?? "Внешний сервис не вернул ссылку на видео"
        throw Abort(.internalServerError, reason: reason)
    }
}

