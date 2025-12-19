import Foundation

/// Actor для thread-safe хранения file_id видео пользователей
/// Используется для сохранения file_id при проверке подписки
actor VideoSessionManager {
    struct Session {
        var fileId: String
        var duration: Int // Длительность видео в секундах
        var timestamp: Date // Время сохранения (для очистки старых)
    }
    
    static let shared = VideoSessionManager()
    
    private var sessions: [Int64: Session] = [:]
    private let expirationInterval: TimeInterval = 300 // 5 минут - сессия истекает
    
    /// Сохраняет file_id и длительность видео для пользователя
    func saveVideo(userId: Int64, fileId: String, duration: Int) {
        sessions[userId] = Session(
            fileId: fileId,
            duration: duration,
            timestamp: Date()
        )
    }
    
    /// Получает сохраненные file_id и длительность для пользователя
    func getVideo(userId: Int64) -> (fileId: String, duration: Int)? {
        guard let session = sessions[userId] else {
            return nil
        }
        
        // Проверяем, не истекла ли сессия
        let age = Date().timeIntervalSince(session.timestamp)
        guard age < expirationInterval else {
            // Сессия истекла, удаляем
            sessions[userId] = nil
            return nil
        }
        
        return (session.fileId, session.duration)
    }
    
    /// Очищает сессию для пользователя (после успешной обработки)
    func clearVideo(userId: Int64) {
        sessions[userId] = nil
    }
    
    /// Очищает все истекшие сессии (можно вызывать периодически)
    func cleanupExpired() {
        let now = Date()
        sessions = sessions.filter { _, session in
            now.timeIntervalSince(session.timestamp) < expirationInterval
        }
    }
}

