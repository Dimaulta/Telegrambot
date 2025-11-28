import Vapor
import Foundation

struct OpenAIModerationClient {
    struct AnalysisResult {
        let flagged: Bool
        let violations: [String]
    }

    private let apiKey: String
    private let client: Client

    private let allocator = ByteBufferAllocator()

    init(request: Request) throws {
        guard let apiKey = Environment.get("OPENAI_API_KEY"), !apiKey.isEmpty else {
            throw Abort(.internalServerError, reason: "OPENAI_API_KEY is not set")
        }
        self.apiKey = apiKey
        self.client = request.client
    }

    func analyze(text: String) async throws -> AnalysisResult {
        let url = URI(string: "https://api.openai.com/v1/moderations")
        let payload = OpenAIRequest(model: "omni-moderation-latest", input: text)
        let data = try JSONEncoder().encode(payload)
        var buffer = allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)

        var request = ClientRequest(method: .POST, url: url)
        request.headers.add(name: .authorization, value: "Bearer \(apiKey)")
        request.headers.add(name: .contentType, value: "application/json")
        request.body = buffer

        let response = try await client.send(request)
        guard response.status == .ok else {
            let errorBody = response.body.flatMap { buffer -> String in
                var copy = buffer
                return copy.readString(length: copy.readableBytes) ?? ""
            } ?? ""
            throw Abort(.badRequest, reason: "OpenAI moderation error: \(response.status) - \(errorBody)")
        }

        guard let body = response.body else {
            throw Abort(.badRequest, reason: "OpenAI moderation response is empty")
        }

        let responseData = body.getData(at: 0, length: body.readableBytes) ?? Data()
        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: responseData)
        guard let result = decoded.results.first else {
            return .init(flagged: false, violations: [])
        }
        let violations = result.categories
            .filter { $0.value }
            .map { $0.key }

        return .init(flagged: result.flagged, violations: violations)
    }
}

private struct OpenAIRequest: Encodable {
    let model: String
    let input: String
}

private struct OpenAIResponse: Decodable {
    struct Result: Decodable {
        let flagged: Bool
        let categories: [String: Bool]
    }

    let results: [Result]
}

