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
        let trimmed = originalUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: "Empty TikTok URL")
        }
        
        let normalized = await normalizeTikTokURL(trimmed)
        logger.info("Normalized TikTok URL: \(normalized)")
        guard normalized.contains("tiktok.com") else {
            throw Abort(.badRequest, reason: "Invalid TikTok URL")
        }
        
        // Пробуем провайдеры последовательно с retry
        let providers: [(String) async throws -> String] = [
            resolveViaTikWM,
            resolveViaTiklyDown,
            resolveViaTikmate,
            resolveViaSnapTik,
            resolveViaSSSTik
        ]
        
        var lastError: Error?
        var failedProviders: [String] = []
        
        for (index, provider) in providers.enumerated() {
            let providerNames = ["TikWM", "TiklyDown", "Tikmate", "SnapTik", "SSSTik"]
            let providerName = providerNames[index]
            
            do {
                let result = try await provider(normalized)
                if !result.isEmpty {
                    logger.info("✅ Successfully resolved via \(providerName)")
                    return result
                }
            } catch {
                lastError = error
                failedProviders.append(providerName)
                logger.warning("❌ \(providerName) failed: \(error.localizedDescription)")
                continue
            }
        }
        
        // Все провайдеры не сработали
        logger.error("❌ All providers failed: \(failedProviders.joined(separator: ", "))")
        throw TikTokResolverError.allProvidersFailed(failedProviders: failedProviders)
    }
    
    enum TikTokResolverError: AbortError {
        case allProvidersFailed(failedProviders: [String])
        
        var status: HTTPResponseStatus {
            .badRequest
        }
        
        var reason: String {
            switch self {
            case .allProvidersFailed:
                return "Failed to resolve video URL from all providers"
            }
        }
    }
    
    // Общий метод для запросов с обработкой 429 и retry
    private func makeRequest(
        uri: URI,
        method: HTTPMethod = .GET,
        headers: HTTPHeaders,
        body: ByteBuffer? = nil,
        providerName: String,
        maxRetries: Int = 3
    ) async throws -> ClientResponse {
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            do {
                var request = ClientRequest(method: method, url: uri)
                request.headers = headers
                if let body = body {
                    request.body = body
                }
                
                let response = try await client.send(request)
                
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
                
                guard response.status == .ok else {
                    logger.warning("\(providerName) returned status \(response.status.code)")
                    throw Abort(.badRequest, reason: "\(providerName) status \(response.status.code)")
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
    
    private func normalizeTikTokURL(_ url: String) async -> String {
        var current = url.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Ручная нормализация коротких ссылок
        if current.contains("vt.tiktok.com/") || current.contains("vm.tiktok.com/") {
            // Извлекаем ID из короткой ссылки для логирования
            if extractShortId(from: current) != nil {
                // Пробуем получить полную ссылку через редирект
                logger.info("Normalizing short TikTok URL: \(current)")
            }
        }
        
        let maxRedirects = 5
        var attempts = 0
        
        while attempts < maxRedirects {
            attempts += 1
            guard URL(string: current) != nil else { break }
            
            // Пробуем сначала HEAD, если не работает - GET
            var request = ClientRequest(method: .HEAD, url: URI(string: current))
            request.headers.add(name: "User-Agent", value: "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/537.36 (KHTML, like Gecko) VaporBot/1.0")
            
            do {
                let response = try await client.send(request)
                let status = response.status.code
                if (300...399).contains(status),
                   let location = response.headers.first(name: "Location"),
                   !location.isEmpty {
                    if location.hasPrefix("http") {
                        current = location
                    } else {
                        current = "https://www.tiktok.com\(location)"
                    }
                    logger.info("TikTok URL redirected to: \(current)")
                    continue
                } else if status == 200 {
                    // Если HEAD вернул 200, пробуем GET для получения финального URL
                    var getRequest = ClientRequest(method: .GET, url: URI(string: current))
                    getRequest.headers.add(name: "User-Agent", value: "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/537.36 (KHTML, like Gecko) VaporBot/1.0")
                    let getResponse = try await client.send(getRequest)
                    if (300...399).contains(getResponse.status.code),
                       let location = getResponse.headers.first(name: "Location"),
                       !location.isEmpty {
                        current = location.hasPrefix("http") ? location : "https://www.tiktok.com\(location)"
                        logger.info("TikTok URL normalized via GET to: \(current)")
                    }
                    return current
                } else {
                    return current
                }
            } catch {
                logger.warning("Failed to normalize TikTok URL \(current): \(error.localizedDescription)")
                // Если HEAD не работает, возвращаем исходный URL
                break
            }
        }
        return current
    }
    
    private func extractShortId(from url: String) -> String? {
        // Извлекаем ID из коротких ссылок типа vt.tiktok.com/XXX или vm.tiktok.com/XXX
        let patterns = [
            "vt\\.tiktok\\.com/([A-Za-z0-9]+)",
            "vm\\.tiktok\\.com/([A-Za-z0-9]+)"
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
               let range = Range(match.range(at: 1), in: url) {
                return String(url[range])
            }
        }
        return nil
    }
    
    private func resolveViaTikWM(url: String) async throws -> String {
        let startTime = Date()
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
        guard var body = res.body else {
            logger.warning("TikWM: empty response body")
            throw Abort(.badRequest, reason: "TikWM empty response")
        }
        
        let readableBytes = body.readableBytes
        logger.info("TikWM: body readableBytes = \(readableBytes)")
        
        guard let data = body.readData(length: readableBytes) else {
            logger.warning("TikWM: failed to read body data")
            throw Abort(.badRequest, reason: "TikWM failed to read response")
        }
        
        logger.info("TikWM: body data size = \(data.count) bytes")
        
        do {
            struct TikWMResponse: Decodable { let code: Int; let msg: String?; let data: TikWMData? }
            struct TikWMData: Decodable { let hdplay: String?; let play: String? }
            let decoded = try JSONDecoder().decode(TikWMResponse.self, from: data)
            
            // Проверяем code в ответе
            if decoded.code != 0 {
                let msg = decoded.msg ?? "unknown error"
                logger.warning("TikWM: bad code \(decoded.code), msg: \(msg)")
                throw Abort(.badRequest, reason: "TikWM bad code: \(decoded.code) - \(msg)")
            }
            
            guard let d = decoded.data else {
                logger.warning("TikWM: no data in response")
                throw Abort(.badRequest, reason: "TikWM no data in response")
            }
            
            if let hd = d.hdplay, !hd.isEmpty {
                let duration = Date().timeIntervalSince(startTime)
                logger.info("✅ TikWM: success (HD), duration: \(String(format: "%.2f", duration))s")
                return hd
            }
            if let play = d.play, !play.isEmpty {
                let duration = Date().timeIntervalSince(startTime)
                logger.info("✅ TikWM: success (SD), duration: \(String(format: "%.2f", duration))s")
                return play
            }
            
            logger.warning("TikWM: no playable url in response")
            throw Abort(.badRequest, reason: "TikWM no playable url")
        } catch {
            if let bodyString = String(data: data, encoding: .utf8) {
                logger.warning("TikWM: invalid response format, snippet: \(bodyString.prefix(500))")
            } else {
                logger.warning("TikWM: invalid response format, data size: \(data.count)")
            }
            throw Abort(.badRequest, reason: "TikWM invalid response format: \(error.localizedDescription)")
        }
    }
    
    private func resolveViaTiklyDown(url: String) async throws -> String {
        let startTime = Date()
        var comps = URLComponents(string: "https://api.tiklydown.me/api/download")!
        comps.queryItems = [URLQueryItem(name: "url", value: url)]
        let uri = URI(string: comps.url!.absoluteString)
        let headers: HTTPHeaders = [
            "Accept": "application/json",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/537.36 (KHTML, like Gecko) VaporBot/1.0"
        ]
        logger.info("TiklyDown request: \(uri)")
        
        let res = try await makeRequest(uri: uri, headers: headers, providerName: "TiklyDown")
        guard var body = res.body else {
            logger.warning("TiklyDown: empty response body")
            throw Abort(.badRequest, reason: "TiklyDown empty response")
        }
        
        let readableBytes = body.readableBytes
        logger.info("TiklyDown: body readableBytes = \(readableBytes)")
        
        guard let data = body.readData(length: readableBytes) else {
            logger.warning("TiklyDown: failed to read body data")
            throw Abort(.badRequest, reason: "TiklyDown failed to read response")
        }
        
        logger.info("TiklyDown: body data size = \(data.count) bytes")
        
        do {
            struct TDResp: Decodable { let status: Bool; let video: TDVideo? }
            struct TDVideo: Decodable { let noWatermark: String?; let hd: String?; let watermark: String? }
            let decoded = try JSONDecoder().decode(TDResp.self, from: data)
            guard decoded.status, let v = decoded.video else {
                logger.warning("TiklyDown: bad status or no video")
                throw Abort(.badRequest, reason: "TiklyDown bad status")
            }
            if let url = v.noWatermark, !url.isEmpty {
                let duration = Date().timeIntervalSince(startTime)
                logger.info("✅ TiklyDown: success (no watermark), duration: \(String(format: "%.2f", duration))s")
                return url
            }
            if let url = v.hd, !url.isEmpty {
                let duration = Date().timeIntervalSince(startTime)
                logger.info("✅ TiklyDown: success (HD), duration: \(String(format: "%.2f", duration))s")
                return url
            }
            if let url = v.watermark, !url.isEmpty {
                let duration = Date().timeIntervalSince(startTime)
                logger.info("✅ TiklyDown: success (with watermark), duration: \(String(format: "%.2f", duration))s")
                return url
            }
            logger.warning("TiklyDown: no playable url")
            throw Abort(.badRequest, reason: "TiklyDown no playable url")
        } catch {
            if let bodyString = String(data: data, encoding: .utf8) {
                logger.warning("TiklyDown: invalid response format, snippet: \(bodyString.prefix(500))")
            } else {
                logger.warning("TiklyDown: invalid response format, data size: \(data.count)")
            }
            throw Abort(.badRequest, reason: "TiklyDown invalid response format: \(error.localizedDescription)")
        }
    }
    
    private func resolveViaTikmate(url: String) async throws -> String {
        let startTime = Date()
        var comps = URLComponents(string: "https://api.tikmate.app/api/lookup")!
        comps.queryItems = [URLQueryItem(name: "url", value: url)]
        let uri = URI(string: comps.url!.absoluteString)
        let headers: HTTPHeaders = [
            "Accept": "application/json",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/537.36 (KHTML, like Gecko) VaporBot/1.0"
        ]
        logger.info("Tikmate request: \(uri)")
        
        let res = try await makeRequest(uri: uri, headers: headers, providerName: "Tikmate")
        guard var body = res.body else {
            logger.warning("Tikmate: empty response body")
            throw Abort(.badRequest, reason: "Tikmate empty response")
        }
        
        let readableBytes = body.readableBytes
        logger.info("Tikmate: body readableBytes = \(readableBytes)")
        
        guard let data = body.readData(length: readableBytes) else {
            logger.warning("Tikmate: failed to read body data")
            throw Abort(.badRequest, reason: "Tikmate failed to read response")
        }
        
        logger.info("Tikmate: body data size = \(data.count) bytes")
        
        if let json = try? JSONSerialization.jsonObject(with: data, options: []) {
            if let url = extractFirstVideoURL(from: json) {
                let duration = Date().timeIntervalSince(startTime)
                logger.info("✅ Tikmate: success, duration: \(String(format: "%.2f", duration))s")
                return url
            }
        }
        
        if let bodyString = String(data: data, encoding: .utf8) {
            logger.warning("Tikmate: no playable url, response snippet: \(bodyString.prefix(500))")
        } else {
            logger.warning("Tikmate: no playable url, data size: \(data.count)")
        }
        throw Abort(.badRequest, reason: "Tikmate no playable url")
    }
    
    private func resolveViaSnapTik(url: String) async throws -> String {
        let startTime = Date()
        // https://snaptik.app/api/ajaxSearch
        let uri = URI(string: "https://snaptik.app/api/ajaxSearch")
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/x-www-form-urlencoded")
        headers.add(name: "User-Agent", value: "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/537.36 (KHTML, like Gecko) VaporBot/1.0")
        
        logger.info("SnapTik request: \(uri)")
        let bodyString = "url=\(url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url)"
        var requestBody = ByteBufferAllocator().buffer(capacity: bodyString.utf8.count)
        requestBody.writeString(bodyString)
        let res = try await makeRequest(uri: uri, method: .POST, headers: headers, body: requestBody, providerName: "SnapTik")
        guard var body = res.body else {
            logger.warning("SnapTik: empty response body")
            throw Abort(.badRequest, reason: "SnapTik empty response")
        }
        
        let readableBytes = body.readableBytes
        logger.info("SnapTik: body readableBytes = \(readableBytes)")
        
        guard let data = body.readData(length: readableBytes) else {
            logger.warning("SnapTik: failed to read body data")
            throw Abort(.badRequest, reason: "SnapTik failed to read response")
        }
        
        logger.info("SnapTik: body data size = \(data.count) bytes")
        
        // SnapTik возвращает HTML или JSON в зависимости от версии API
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let videoUrl = json["url"] as? String, !videoUrl.isEmpty {
            let duration = Date().timeIntervalSince(startTime)
            logger.info("✅ SnapTik: success, duration: \(String(format: "%.2f", duration))s")
            return videoUrl
        }
        if let json = try? JSONSerialization.jsonObject(with: data, options: []),
           let videoUrl = extractFirstVideoURL(from: json) {
            let duration = Date().timeIntervalSince(startTime)
            logger.info("✅ SnapTik: success, duration: \(String(format: "%.2f", duration))s")
            return videoUrl
        }
        if let bodyStr = String(data: data, encoding: .utf8) {
            logger.warning("SnapTik: no playable url, response snippet: \(bodyStr.prefix(500))")
        } else {
            logger.warning("SnapTik: no playable url, data size: \(data.count)")
        }
        
        throw Abort(.badRequest, reason: "SnapTik no playable url")
    }
    
    private func resolveViaSSSTik(url: String) async throws -> String {
        let startTime = Date()
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
        guard var body = res.body else {
            logger.warning("SSSTik: empty response body")
            throw Abort(.badRequest, reason: "SSSTik empty response")
        }
        
        let readableBytes = body.readableBytes
        logger.info("SSSTik: body readableBytes = \(readableBytes)")
        
        guard let data = body.readData(length: readableBytes) else {
            logger.warning("SSSTik: failed to read body data")
            throw Abort(.badRequest, reason: "SSSTik failed to read response")
        }
        
        logger.info("SSSTik: body data size = \(data.count) bytes")
        
        // SSSTik может возвращать разные форматы
        if let json = try? JSONSerialization.jsonObject(with: data, options: []) {
            if let videoUrl = extractFirstVideoURL(from: json) {
                let duration = Date().timeIntervalSince(startTime)
                logger.info("✅ SSSTik: success, duration: \(String(format: "%.2f", duration))s")
                return videoUrl
            }
        }
        
        if let bodyString = String(data: data, encoding: .utf8) {
            logger.warning("SSSTik: no playable url, response snippet: \(bodyString.prefix(500))")
        } else {
            logger.warning("SSSTik: no playable url, data size: \(data.count)")
        }
        throw Abort(.badRequest, reason: "SSSTik no playable url")
    }
    
    private func extractFirstVideoURL(from object: Any) -> String? {
        if let string = object as? String,
           string.contains("http"),
           (string.contains(".mp4") || string.contains(".m3u8") || string.contains("download")) {
            return string
        }
        if let dict = object as? [String: Any] {
            for value in dict.values {
                if let url = extractFirstVideoURL(from: value) {
                    return url
                }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let url = extractFirstVideoURL(from: value) {
                    return url
                }
            }
        }
        return nil
    }
}
