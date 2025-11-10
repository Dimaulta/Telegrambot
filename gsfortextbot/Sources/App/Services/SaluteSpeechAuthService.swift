import Vapor
import Foundation

actor SaluteSpeechAuthService {
    private struct CachedToken {
        let value: String
        let expiresAt: Date
    }
    
    private let app: Application
    private let tokenURI: URI
    private let scope: String
    private let authKey: String
    private let refreshLeeway: TimeInterval
    private var cachedToken: CachedToken?
    
    init(app: Application) {
        self.app = app
        let tokenURLString = Environment.get("SALUTESPEECH_TOKEN_URL") ?? "https://ngw.devices.sberbank.ru:9443/api/v2/oauth"
        self.tokenURI = URI(string: tokenURLString)
        self.scope = Environment.get("SALUTESPEECH_SCOPE") ?? "SALUTE_SPEECH_PERS"
        self.authKey = Environment.get("SALUTESPEECH_AUTH_KEY") ?? ""
        if let leewayString = Environment.get("SALUTESPEECH_TOKEN_EPSILON_SECONDS"),
           let seconds = Double(leewayString), seconds >= 0 {
            self.refreshLeeway = seconds
        } else {
            self.refreshLeeway = 60
        }
    }
    
    func currentToken(forceRefresh: Bool = false, logger: Logger) async throws -> String {
        guard authKey.isEmpty == false else {
            logger.error("SaluteSpeechAuthService: SALUTESPEECH_AUTH_KEY is not configured")
            throw Abort(.internalServerError, reason: "Мой хороший, нужно указать SALUTESPEECH_AUTH_KEY в config/.env")
        }
        
        if forceRefresh == false, let cached = cachedToken {
            let graceDate = cached.expiresAt.addingTimeInterval(-refreshLeeway)
            if graceDate > Date() {
                return cached.value
            }
        }
        
        let fresh = try await fetchToken(logger: logger)
        cachedToken = fresh
        return fresh.value
    }
    
    private func fetchToken(logger: Logger) async throws -> CachedToken {
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/x-www-form-urlencoded")
        headers.add(name: .accept, value: "application/json")
        headers.add(name: "RqUID", value: UUID().uuidString)
        headers.add(name: .authorization, value: "Basic \(authKey)")
        
        let bodyString = "scope=\(scope)"
        
        let response = try await app.client.post(tokenURI, headers: headers) { request in
            request.body = .init(string: bodyString)
        }
        
        guard var responseBody = response.body,
              let data = responseBody.readData(length: responseBody.readableBytes) else {
            logger.error("SaluteSpeechAuthService: empty token response body, status=\(response.status)")
            throw Abort(.internalServerError, reason: "Не удалось получить токен доступа SaluteSpeech (пустой ответ)")
        }
        
        let decoder = JSONDecoder()
        let tokenResponse: TokenResponse
        do {
            tokenResponse = try decoder.decode(TokenResponse.self, from: data)
        } catch {
            let rawString = String(data: data, encoding: .utf8) ?? ""
            logger.error("SaluteSpeechAuthService: failed to decode token response: \(rawString)")
            throw Abort(.internalServerError, reason: "Не удалось разобрать ответ авторизации SaluteSpeech")
        }
        
        guard response.status == .ok else {
            let reason = tokenResponse.message ?? response.status.reasonPhrase
            logger.error("SaluteSpeechAuthService: token request failed, status=\(response.status), reason=\(reason)")
            throw Abort(.internalServerError, reason: "SaluteSpeech вернул ошибку при выдаче токена: \(reason)")
        }
        
        let expiryDate: Date
        if let expiresAt = tokenResponse.expiresAt {
            expiryDate = Date(timeIntervalSince1970: Double(expiresAt) / 1000.0)
        } else if let expiresIn = tokenResponse.expiresIn {
            expiryDate = Date().addingTimeInterval(TimeInterval(expiresIn))
        } else {
            // Fallback to 25 minutes if API does not provide explicit TTL
            expiryDate = Date().addingTimeInterval(1500)
        }
        
        logger.info("SaluteSpeechAuthService: obtained new token, expires at \(expiryDate)")
        return CachedToken(value: tokenResponse.accessToken, expiresAt: expiryDate)
    }
    
    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresAt: Int?
        let expiresIn: Int?
        let message: String?
        
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresAt = "expires_at"
            case expiresIn = "expires_in"
            case message
        }
    }
}

