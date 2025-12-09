import Foundation

/// Actor для thread-safe хранения тем постов пользователей
/// Используется для сохранения темы при проверке подписки
actor TopicSessionManager {
    struct Session {
        var topic: String
        var channelId: UUID? // Опционально, если нужно знать для какого канала тема
        var timestamp: Date // Время сохранения темы (для очистки старых)
    }
    
    static let shared = TopicSessionManager()
    
    private var sessions: [Int64: Session] = [:]
    private let expirationInterval: TimeInterval = 300 // 5 минут - тема истекает
    
    /// Сохраняет тему для пользователя
    func saveTopic(userId: Int64, topic: String, channelId: UUID? = nil) {
        sessions[userId] = Session(
            topic: topic,
            channelId: channelId,
            timestamp: Date()
        )
    }
    
    /// Получает сохраненную тему для пользователя
    func getTopic(userId: Int64) -> (topic: String, channelId: UUID?)? {
        guard let session = sessions[userId] else {
            return nil
        }
        
        // Проверяем, не истекла ли тема
        let age = Date().timeIntervalSince(session.timestamp)
        guard age < expirationInterval else {
            // Тема истекла, удаляем
            sessions[userId] = nil
            return nil
        }
        
        return (session.topic, session.channelId)
    }
    
    /// Очищает тему для пользователя (после успешной генерации)
    func clearTopic(userId: Int64) {
        sessions[userId] = nil
    }
    
    /// Очищает все истекшие темы (можно вызывать периодически)
    func cleanupExpired() {
        let now = Date()
        sessions = sessions.filter { _, session in
            now.timeIntervalSince(session.timestamp) < expirationInterval
        }
    }
}

