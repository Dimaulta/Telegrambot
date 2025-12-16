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
        return try await executeWithRetry {
            let encodedPath = encodePath(path)
            var uri = config.url
            uri.path = "/storage/v1/object/\(config.bucket)/\(encodedPath)"

            var request = ClientRequest(method: .POST, url: uri)
            request.headers = authorizedHeaders(contentType: contentType, upsert: upsert)
            request.body = data
            request.timeout = .seconds(30) // Таймаут 30 секунд для upload

            let response = try await client.send(request)
            guard response.status == .ok || response.status == .created else {
                throw Abort(.badRequest, reason: "Supabase upload failed: \(response.status) - \(bodyString(from: response.body))")
            }
            return normalizePath(path)
        }
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
        return try await executeWithRetry {
            let urlString = publicURL(for: path)
            guard let url = URL(string: urlString) else {
                throw Abort(.badRequest, reason: "Public URL is invalid")
            }
            var request = ClientRequest(method: .GET, url: URI(string: url.absoluteString))
            request.timeout = .seconds(30) // Таймаут 30 секунд для download
            
            let response = try await client.send(request)
            guard response.status == .ok else {
                throw Abort(.badRequest, reason: "Supabase download failed: \(response.status) - \(bodyString(from: response.body))")
            }
            guard var body = response.body else {
                throw Abort(.badRequest, reason: "Supabase download response is empty")
            }
            return body.readData(length: body.readableBytes) ?? Data()
        }
    }
    
    /// Легкий запрос для keep-alive (предотвращает паузу проекта)
    /// Возвращает true если запрос успешен, false при ошибке
    func ping() async -> Bool {
        var uri = config.url
        uri.path = "/storage/v1/bucket/\(config.bucket)"
        
        var request = ClientRequest(method: .GET, url: uri)
        request.headers = authorizedHeaders()
        request.timeout = .seconds(15) // Таймаут 15 секунд
        
        do {
            let response = try await client.send(request)
            return response.status == .ok
        } catch {
            return false
        }
    }
    
    /// Выполняет операцию с автоматическим retry при ошибках
    func executeWithRetry<T>(
        maxRetries: Int = 3,
        retryDelays: [TimeInterval] = [1.0, 3.0, 5.0],
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        
        for attempt in 0..<maxRetries {
            do {
                return try await operation()
            } catch {
                lastError = error
                
                // Если это последняя попытка, выбрасываем ошибку
                if attempt == maxRetries - 1 {
                    throw error
                }
                
                // Ждём перед следующей попыткой
                let delay = retryDelays[min(attempt, retryDelays.count - 1)]
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        
        throw lastError ?? Abort(.internalServerError, reason: "Retry failed")
    }
}

