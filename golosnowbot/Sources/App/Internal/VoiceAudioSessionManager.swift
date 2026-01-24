import Foundation

/// Actor для thread-safe хранения file_id голосовых/аудио сообщений пользователей
/// Используется для сохранения file_id и типа при проверке подписки
actor VoiceAudioSessionManager {
    enum MediaType {
        case voice
        case audio
    }
    
    struct Session {
        var fileId: String
        var type: MediaType
        var duration: Int? // Длительность в секундах (опционально)
        var mimeType: String? // MIME тип (опционально)
        var timestamp: Date // Время сохранения (для очистки старых)
    }
    
    static let shared = VoiceAudioSessionManager()
    
    private var sessions: [Int64: Session] = [:]
    private let expirationInterval: TimeInterval = 300 // 5 минут - сессия истекает
    
    /// Сохраняет file_id, тип, длительность и MIME тип для пользователя
    func saveMedia(userId: Int64, fileId: String, type: MediaType, duration: Int? = nil, mimeType: String? = nil) {
        sessions[userId] = Session(
            fileId: fileId,
            type: type,
            duration: duration,
            mimeType: mimeType,
            timestamp: Date()
        )
    }
    
    /// Получает сохраненные данные для пользователя
    func getMedia(userId: Int64) -> (fileId: String, type: MediaType, duration: Int?, mimeType: String?)? {
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
        
        return (session.fileId, session.type, session.duration, session.mimeType)
    }
    
    /// Очищает сессию для пользователя (после успешной обработки)
    func clearMedia(userId: Int64) {
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

