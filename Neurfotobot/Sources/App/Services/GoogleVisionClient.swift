import Vapor
import Foundation

struct GoogleVisionClient {
    private let apiKey: String
    private let client: Client

    init(request: Request) throws {
        guard let key = Environment.get("GOOGLE_VISION_API_KEY"), !key.isEmpty else {
            throw Abort(.internalServerError, reason: "GOOGLE_VISION_API_KEY is not set")
        }
        self.apiKey = key
        self.client = request.client
    }

    func analyzeSafeSearch(data: Data) async throws -> GoogleSafeSearchAnnotation {
        let payload = GoogleVisionRequest(
            requests: [
                GoogleVisionRequest.Request(
                    image: .init(content: data.base64EncodedString()),
                    features: [GoogleVisionRequest.Request.Feature(type: "SAFE_SEARCH_DETECTION")]
                )
            ]
        )

        let url = URI(string: "https://vision.googleapis.com/v1/images:annotate?key=\(apiKey)")
        var request = ClientRequest(method: .POST, url: url)
        request.headers.add(name: .contentType, value: "application/json")
        request.body = try .init(data: JSONEncoder().encode(payload))

        let response = try await client.send(request)
        guard response.status == .ok, let body = response.body else {
            let errorBody = response.body?.string ?? ""
            throw Abort(.badRequest, reason: "Google Vision error: \(response.status) - \(errorBody)")
        }

        let data = body.getData(at: 0, length: body.readableBytes) ?? Data()
        let decoded = try JSONDecoder().decode(GoogleVisionResponse.self, from: data)
        guard let first = decoded.responses.first, let annotation = first.safeSearchAnnotation else {
            throw Abort(.badRequest, reason: "Google Vision returned empty response")
        }
        return annotation
    }
}

struct GoogleSafeSearchAnnotation: Decodable {
    let adult: String
    let spoof: String?
    let medical: String?
    let violence: String?
    let racy: String?
}

private struct GoogleVisionRequest: Encodable {
    struct Request: Encodable {
        struct Image: Encodable { let content: String }
        struct Feature: Encodable { let type: String }

        let image: Image
        let features: [Feature]
    }

    let requests: [Request]
}

private struct GoogleVisionResponse: Decodable {
    struct Response: Decodable {
        let safeSearchAnnotation: GoogleSafeSearchAnnotation?
    }

    let responses: [Response]
}

