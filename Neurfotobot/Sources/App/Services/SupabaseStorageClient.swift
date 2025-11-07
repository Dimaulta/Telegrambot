import Vapor

struct SupabaseStorageConfig {
    let url: URI
    let bucket: String
    let serviceKey: String

    static func load(from environment: EnvironmentValues) throws -> SupabaseStorageConfig {
        guard let urlString = Environment.get("SUPABASE_URL"), let url = URI(string: urlString) else {
            throw Abort(.internalServerError, reason: "SUPABASE_URL is not set")
        }
        guard let bucket = Environment.get("SUPABASE_BUCKET"), !bucket.isEmpty else {
            throw Abort(.internalServerError, reason: "SUPABASE_BUCKET is not set")
        }
        guard let serviceKey = Environment.get("SUPABASE_SERVICE_KEY"), !serviceKey.isEmpty else {
            throw Abort(.internalServerError, reason: "SUPABASE_SERVICE_KEY is not set")
        }
        return SupabaseStorageConfig(url: url, bucket: bucket, serviceKey: serviceKey)
    }
}

struct SupabaseStorageClient {
    private let config: SupabaseStorageConfig
    private let client: Client

    init(request: Request) throws {
        self.config = try SupabaseStorageConfig.load(from: request.environment)
        self.client = request.client
    }

    init(application: Application) throws {
        self.config = try SupabaseStorageConfig.load(from: application.environment)
        self.client = application.client
    }

    private var baseStorageURI: URI {
        var uri = config.url
        uri.path = "/storage/v1"
        return uri
    }

    private func authorizedHeaders(contentType: String? = nil, upsert: Bool = false) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.add(name: .authorization, value: "Bearer \(config.serviceKey)")
        if let contentType {
            headers.add(name: .contentType, value: contentType)
        }
        if upsert {
            headers.add(name: "x-upsert", value: "true")
        }
        return headers
    }

    @discardableResult
    func upload(path: String, data: ByteBuffer, contentType: String, upsert: Bool = true) async throws -> String {
        var uri = baseStorageURI
        uri.path += "/object/\(config.bucket)/\(path)"

        var request = ClientRequest(method: .post, url: uri)
        request.headers = authorizedHeaders(contentType: contentType, upsert: upsert)
        request.body = .init(buffer: data)

        let response = try await client.send(request)
        guard response.status == .ok || response.status == .created else {
            let errorBody = response.body?.string ?? "unknown error"
            throw Abort(.badRequest, reason: "Supabase upload failed: \(response.status) - \(errorBody)")
        }
        return path
    }

    func createSignedURL(path: String, expiresIn seconds: Int = 3600) async throws -> String {
        struct Payload: Content { let expiresIn: Int }
        struct ResponseBody: Content { let signedURL: String }

        var uri = baseStorageURI
        uri.path += "/object/sign/\(config.bucket)/\(path)"

        var request = ClientRequest(method: .post, url: uri)
        request.headers = authorizedHeaders(contentType: "application/json")
        let payload = Payload(expiresIn: seconds)
        request.body = try .init(data: JSONEncoder().encode(payload))

        let response = try await client.send(request)
        guard response.status == .ok else {
            let errorBody = response.body?.string ?? "unknown error"
            throw Abort(.badRequest, reason: "Supabase signed URL failed: \(response.status) - \(errorBody)")
        }

        guard let body = response.body else {
            throw Abort(.badRequest, reason: "Supabase signed URL response is empty")
        }

        let data = body.getData(at: 0, length: body.readableBytes) ?? Data()
        let decoder = JSONDecoder()
        let responseBody = try decoder.decode(ResponseBody.self, from: data)
        return responseBody.signedURL
    }

    func delete(path: String) async throws {
        var uri = baseStorageURI
        uri.path += "/object/\(config.bucket)/\(path)"

        var request = ClientRequest(method: .delete, url: uri)
        request.headers = authorizedHeaders()

        let response = try await client.send(request)
        guard response.status == .ok || response.status == .noContent else {
            let errorBody = response.body?.string ?? "unknown error"
            throw Abort(.badRequest, reason: "Supabase delete failed: \(response.status) - \(errorBody)")
        }
    }
}

