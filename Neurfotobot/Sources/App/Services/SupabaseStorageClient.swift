import Vapor
import Foundation

struct SupabaseStorageConfig {
    let url: URI
    let bucket: String
    let serviceKey: String

    static func load() throws -> SupabaseStorageConfig {
        guard let urlString = Environment.get("SUPABASE_URL") else {
            throw Abort(.internalServerError, reason: "SUPABASE_URL is not set")
        }
        guard let bucket = Environment.get("SUPABASE_BUCKET"), !bucket.isEmpty else {
            throw Abort(.internalServerError, reason: "SUPABASE_BUCKET is not set")
        }
        guard let serviceKey = Environment.get("SUPABASE_SERVICE_KEY"), !serviceKey.isEmpty else {
            throw Abort(.internalServerError, reason: "SUPABASE_SERVICE_KEY is not set")
        }
        return SupabaseStorageConfig(url: URI(string: urlString), bucket: bucket, serviceKey: serviceKey)
    }
}

struct SupabaseStorageClient {
    private let config: SupabaseStorageConfig
    private let client: Client
    private let bufferAllocator = ByteBufferAllocator()
    private let pathComponentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/")
        return set
    }()

    init(request: Request) throws {
        self.config = try SupabaseStorageConfig.load()
        self.client = request.client
    }

    init(application: Application) throws {
        self.config = try SupabaseStorageConfig.load()
        self.client = application.client
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

    private func makeBody(from data: Data) -> ByteBuffer {
        var buffer = bufferAllocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }

    private func bodyString(from body: ByteBuffer?) -> String {
        guard var body else { return "" }
        return body.readString(length: body.readableBytes) ?? ""
    }

    private func encodePath(_ path: String) -> String {
        path
            .split(separator: "/")
            .map { component in
                component.addingPercentEncoding(withAllowedCharacters: pathComponentAllowed) ?? String(component)
            }
            .joined(separator: "/")
    }

    @discardableResult
    func upload(path: String, data: ByteBuffer, contentType: String, upsert: Bool = true) async throws -> String {
        let encodedPath = encodePath(path)
        var uri = config.url
        uri.path = "/storage/v1/object/\(config.bucket)/\(encodedPath)"

        var request = ClientRequest(method: .POST, url: uri)
        request.headers = authorizedHeaders(contentType: contentType, upsert: upsert)
        request.body = data

        let response = try await client.send(request)
        guard response.status == .ok || response.status == .created else {
            throw Abort(.badRequest, reason: "Supabase upload failed: \(response.status) - \(bodyString(from: response.body))")
        }
        return normalizePath(path)
    }

    private func normalizePath(_ rawPath: String) -> String {
        if rawPath.hasPrefix(config.bucket + "/") {
            return String(rawPath.dropFirst(config.bucket.count + 1))
        }
        return rawPath
    }

    func publicURL(for path: String) -> String {
        let normalized = normalizePath(path)
        let encodedPath = encodePath(normalized)
        var base = config.url.string
        if base.hasSuffix("/") {
            base.removeLast()
        }
        return "\(base)/storage/v1/object/public/\(config.bucket)/\(encodedPath)"
    }

    func delete(path: String) async throws {
        let encodedPath = encodePath(path)
        var uri = config.url
        uri.path = "/storage/v1/object/\(config.bucket)/\(encodedPath)"

        var request = ClientRequest(method: .DELETE, url: uri)
        request.headers = authorizedHeaders()

        let response = try await client.send(request)
        guard response.status == .ok || response.status == .noContent else {
            throw Abort(.badRequest, reason: "Supabase delete failed: \(response.status) - \(bodyString(from: response.body))")
        }
    }

    func download(path: String) async throws -> Data {
        let urlString = publicURL(for: path)
        guard let url = URL(string: urlString) else {
            throw Abort(.badRequest, reason: "Public URL is invalid")
        }
        let response = try await client.get(URI(string: url.absoluteString))
        guard response.status == .ok else {
            throw Abort(.badRequest, reason: "Supabase download failed: \(response.status) - \(bodyString(from: response.body))")
        }
        guard var body = response.body else {
            throw Abort(.badRequest, reason: "Supabase download response is empty")
        }
        return body.readData(length: body.readableBytes) ?? Data()
    }
}

