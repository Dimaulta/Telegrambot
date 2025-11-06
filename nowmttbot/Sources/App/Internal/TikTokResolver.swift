import Vapor
import Foundation

struct TikTokResolver {
    private let client: Client
    private let logger: Logger
    
    init(client: Client, logger: Logger) {
        self.client = client
        self.logger = logger
    }
    
    func resolveDirectVideoUrl(from originalUrl: String) async throws -> String {
        let normalized = originalUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.contains("tiktok.com") else {
            throw Abort(.badRequest, reason: "Invalid TikTok URL")
        }
        
        // Пробуем провайдеры последовательно с retry
        let providers: [(String) async throws -> String] = [
            resolveViaTikWM,
            resolveViaTiklyDown,
            resolveViaSnapTik,
            resolveViaSSSTik
        ]
        
        for provider in providers {
            do {
                let result = try await provider(normalized)
                if !result.isEmpty {
                    return result
                }
            } catch {
                logger.warning("Provider failed: \(error.localizedDescription)")
                continue
            }
        }
        
        throw Abort(.badRequest, reason: "Failed to resolve video URL from all providers")
    }
    
    // Общий метод для запросов с обработкой 429 и retry
    private func makeRequest(uri: URI, headers: HTTPHeaders, providerName: String, maxRetries: Int = 3) async throws -> ClientResponse {
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            do {
                let response = try await client.get(uri, headers: headers).get()
                
                // Обработка HTTP 429 (Rate Limit)
                if response.status == .tooManyRequests {
                    logger.warning("⚠️ Rate limit (429) from \(providerName), attempt \(attempt)/\(maxRetries)")
                    
                    if attempt < maxRetries {
                        // Экспоненциальная задержка: 2^attempt секунд
                        let delay = pow(2.0, Double(attempt))
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    } else {
                        throw Abort(.tooManyRequests, reason: "\(providerName) rate limit exceeded")
                    }
                }
                
                return response
            } catch {
                lastError = error
                if attempt < maxRetries {
                    let delay = pow(2.0, Double(attempt))
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        
        throw lastError ?? Abort(.badRequest, reason: "\(providerName) request failed")
    }
    
    private func resolveViaTikWM(url: String) async throws -> String {
        var comps = URLComponents(string: "https://www.tikwm.com/api/")!
        comps.queryItems = [
            URLQueryItem(name: "url", value: url),
            URLQueryItem(name: "hd", value: "1")
        ]
        let uri = URI(string: comps.url!.absoluteString)
        let headers: HTTPHeaders = [
            "Accept": "application/json",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/537.36 (KHTML, like Gecko) VaporBot/1.0"
        ]
        logger.info("TikWM request: \(uri)")
        
        let res = try await makeRequest(uri: uri, headers: headers, providerName: "TikWM")
        guard let body = res.body else { throw Abort(.badRequest, reason: "TikWM empty response") }
        let data = body.getData(at: 0, length: body.readableBytes) ?? Data()
        struct TikWMResponse: Decodable { let code: Int; let data: TikWMData? }
        struct TikWMData: Decodable { let hdplay: String?; let play: String? }
        let decoded = try JSONDecoder().decode(TikWMResponse.self, from: data)
        guard decoded.code == 0, let d = decoded.data else { throw Abort(.badRequest, reason: "TikWM bad code") }
        if let hd = d.hdplay, !hd.isEmpty { return hd }
        if let play = d.play, !play.isEmpty { return play }
        throw Abort(.badRequest, reason: "TikWM no playable url")
    }
    
    private func resolveViaTiklyDown(url: String) async throws -> String {
        var comps = URLComponents(string: "https://api.tiklydown.me/api/download")!
        comps.queryItems = [URLQueryItem(name: "url", value: url)]
        let uri = URI(string: comps.url!.absoluteString)
        let headers: HTTPHeaders = [
            "Accept": "application/json",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/537.36 (KHTML, like Gecko) VaporBot/1.0"
        ]
        logger.info("TiklyDown request: \(uri)")
        
        let res = try await makeRequest(uri: uri, headers: headers, providerName: "TiklyDown")
        guard let body = res.body else { throw Abort(.badRequest, reason: "TiklyDown empty response") }
        let data = body.getData(at: 0, length: body.readableBytes) ?? Data()
        struct TDResp: Decodable { let status: Bool; let video: TDVideo? }
        struct TDVideo: Decodable { let noWatermark: String?; let hd: String?; let watermark: String? }
        let decoded = try JSONDecoder().decode(TDResp.self, from: data)
        guard decoded.status, let v = decoded.video else { throw Abort(.badRequest, reason: "TiklyDown bad status") }
        if let url = v.noWatermark, !url.isEmpty { return url }
        if let url = v.hd, !url.isEmpty { return url }
        if let url = v.watermark, !url.isEmpty { return url }
        throw Abort(.badRequest, reason: "TiklyDown no playable url")
    }
    
    private func resolveViaSnapTik(url: String) async throws -> String {
        // https://snaptik.app/api/ajaxSearch
        let uri = URI(string: "https://snaptik.app/api/ajaxSearch")
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/x-www-form-urlencoded")
        headers.add(name: "User-Agent", value: "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/537.36 (KHTML, like Gecko) VaporBot/1.0")
        
        var request = ClientRequest(method: .POST, url: uri)
        request.headers = headers
        request.body = ByteBuffer(string: "url=\(url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url)")
        
        logger.info("SnapTik request: \(uri)")
        let res = try await client.send(request)
        
        guard res.status == .ok else {
            if res.status == .tooManyRequests {
                logger.warning("⚠️ Rate limit (429) from SnapTik")
            }
            throw Abort(.badRequest, reason: "SnapTik request failed")
        }
        
        guard let body = res.body else { throw Abort(.badRequest, reason: "SnapTik empty response") }
        let data = body.getData(at: 0, length: body.readableBytes) ?? Data()
        
        // SnapTik возвращает HTML или JSON в зависимости от версии API
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let videoUrl = json["url"] as? String, !videoUrl.isEmpty {
            return videoUrl
        }
        
        throw Abort(.badRequest, reason: "SnapTik no playable url")
    }
    
    private func resolveViaSSSTik(url: String) async throws -> String {
        // https://ssstik.io/api?url=...
        var comps = URLComponents(string: "https://ssstik.io/api")!
        comps.queryItems = [URLQueryItem(name: "url", value: url)]
        let uri = URI(string: comps.url!.absoluteString)
        let headers: HTTPHeaders = [
            "Accept": "application/json",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/537.36 (KHTML, like Gecko) VaporBot/1.0"
        ]
        logger.info("SSSTik request: \(uri)")
        
        let res = try await makeRequest(uri: uri, headers: headers, providerName: "SSSTik")
        guard let body = res.body else { throw Abort(.badRequest, reason: "SSSTik empty response") }
        let data = body.getData(at: 0, length: body.readableBytes) ?? Data()
        
        // SSSTik может возвращать разные форматы
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let videoUrl = json["video"] as? String, !videoUrl.isEmpty {
                return videoUrl
            }
            if let videoUrl = json["url"] as? String, !videoUrl.isEmpty {
                return videoUrl
            }
        }
        
        throw Abort(.badRequest, reason: "SSSTik no playable url")
    }
}
