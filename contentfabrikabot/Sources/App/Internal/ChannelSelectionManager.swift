import Foundation

/// Actor для thread-safe хранения выбранного канала пользователя
/// Используется для сохранения выбранного канала при запросе темы
actor ChannelSelectionManager {
    struct Session {
        var channelId: UUID
        var timestamp: Date // Время сохранения (для очистки старых)
    }
    
    static let shared = ChannelSelectionManager()
    
    private var sessions: [Int64: Session] = [:]
    private let expirationInterval: TimeInterval = 300 // 5 минут - выбор истекает
    
    /// Сохраняет выбранный канал для пользователя
    func saveChannel(userId: Int64, channelId: UUID) {
        sessions[userId] = Session(
            channelId: channelId,
            timestamp: Date()
        )
    }
    
    /// Получает сохраненный канал для пользователя
    func getChannel(userId: Int64) -> UUID? {
        guard let session = sessions[userId] else {
            return nil
        }
        
        // Проверяем, не истек ли выбор
        let age = Date().timeIntervalSince(session.timestamp)
        guard age < expirationInterval else {
            // Выбор истек, удаляем
            sessions[userId] = nil
            return nil
        }
        
        return session.channelId
    }
    
    /// Очищает выбранный канал для пользователя (после успешной генерации или отмены)
    func clearChannel(userId: Int64) {
        sessions[userId] = nil
    }
    
    /// Очищает все истекшие выборы (можно вызывать периодически)
    func cleanupExpired() {
        let now = Date()
        sessions = sessions.filter { _, session in
            now.timeIntervalSince(session.timestamp) < expirationInterval
        }
    }
}
