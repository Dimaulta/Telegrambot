import Foundation

/// Actor для thread-safe хранения TikTok ссылок пользователей
/// Используется для сохранения ссылки при проверке подписки
actor UrlSessionManager {
    struct Session {
        var url: String
        var timestamp: Date // Время сохранения ссылки (для очистки старых)
    }
    
    static let shared = UrlSessionManager()
    
    private var sessions: [Int64: Session] = [:]
    private let expirationInterval: TimeInterval = 300 // 5 минут - ссылка истекает
    
    /// Сохраняет TikTok ссылку для пользователя
    func saveUrl(userId: Int64, url: String) {
        sessions[userId] = Session(
            url: url,
            timestamp: Date()
        )
    }
    
    /// Получает сохраненную ссылку для пользователя
    func getUrl(userId: Int64) -> String? {
        guard let session = sessions[userId] else {
            return nil
        }
        
        // Проверяем, не истекла ли ссылка
        let age = Date().timeIntervalSince(session.timestamp)
        guard age < expirationInterval else {
            // Ссылка истекла, удаляем
            sessions[userId] = nil
            return nil
        }
        
        return session.url
    }
    
    /// Очищает ссылку для пользователя (после успешной обработки)
    func clearUrl(userId: Int64) {
        sessions[userId] = nil
    }
    
    /// Очищает все истекшие ссылки (можно вызывать периодически)
    func cleanupExpired() {
        let now = Date()
        sessions = sessions.filter { _, session in
            now.timeIntervalSince(session.timestamp) < expirationInterval
        }
    }
}

