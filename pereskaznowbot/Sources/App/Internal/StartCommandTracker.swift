import Foundation

/// Actor для thread-safe отслеживания последних обработанных /start команд
/// Используется для предотвращения дубликатов /start с разными update_id
actor StartCommandTracker {
    struct CommandInfo {
        var timestamp: Date
    }
    
    static let shared = StartCommandTracker()
    
    private var lastCommands: [Int64: CommandInfo] = [:]
    private let cooldown: TimeInterval = 5 // 5 секунд между /start
    
    /// Проверяет, можно ли обработать /start для данного chatId
    /// - Returns: true если можно обработать, false если слишком рано
    func canProcess(chatId: Int64) -> Bool {
        let now = Date()
        
        if let lastCommand = lastCommands[chatId] {
            let elapsed = now.timeIntervalSince(lastCommand.timestamp)
            if elapsed < cooldown {
                return false // Слишком рано
            }
        }
        
        // Обновляем время последней обработки
        lastCommands[chatId] = CommandInfo(timestamp: now)
        
        // Очищаем старые записи (старше 1 минуты)
        let oneMinuteAgo = now.addingTimeInterval(-60)
        lastCommands = lastCommands.filter { $0.value.timestamp > oneMinuteAgo }
        
        return true
    }
}

