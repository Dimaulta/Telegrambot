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
        
        // Пробуем последовательно: TikWM → TiklyDown
        if let viaTikWM = try? await resolveViaTikWM(url: normalized), !viaTikWM.isEmpty {
            return viaTikWM
        }
        if let viaTD = try? await resolveViaTiklyDown(url: normalized), !viaTD.isEmpty {
            return viaTD
        }
        throw Abort(.badRequest, reason: "Failed to resolve video URL")
    }
    
    private func resolveViaTikWM(url: String) async throws -> String {
        // https://www.tikwm.com/api/?url=...&hd=1
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
        let res = try await client.get(uri, headers: headers).get()
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
        // https://api.tiklydown.me/api/download?url=...
        var comps = URLComponents(string: "https://api.tiklydown.me/api/download")!
        comps.queryItems = [URLQueryItem(name: "url", value: url)]
        let uri = URI(string: comps.url!.absoluteString)
        let headers: HTTPHeaders = [
            "Accept": "application/json",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/537.36 (KHTML, like Gecko) VaporBot/1.0"
        ]
        logger.info("TiklyDown request: \(uri)")
        let res = try await client.get(uri, headers: headers).get()
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
}


