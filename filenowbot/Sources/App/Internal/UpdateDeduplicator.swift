import Foundation

/// Дедупликатор update_id для предотвращения обработки дубликатов от Telegram
actor UpdateDeduplicator {
    private var processedUpdates = Set<Int>()
    private let maxStoredUpdates = 1000
    
    /// Проверяет, был ли update_id уже обработан, и добавляет его в список
    /// - Returns: true если это дубликат (уже был обработан)
    func checkAndAdd(updateId: Int) -> Bool {
        if processedUpdates.contains(updateId) {
            return true // Дубликат
        }
        
        // Добавляем update_id в список обработанных
        processedUpdates.insert(updateId)
        
        // Ограничиваем размер Set (удаляем старые, если их больше maxStoredUpdates)
        if processedUpdates.count > maxStoredUpdates {
            // Удаляем самые старые (просто очищаем и начинаем заново - это проще)
            // В реальности можно использовать более сложную логику с timestamp
            processedUpdates.removeAll()
        }
        
        return false // Не дубликат
    }
}
