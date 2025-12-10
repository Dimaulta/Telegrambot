import Foundation

/// Трекер обрабатываемых ссылок для предотвращения дубликатов
actor ProcessingLinksTracker {
    private var processingLinks: Set<String> = [] // videoId или URL
    
    /// Проверяет, обрабатывается ли уже эта ссылка
    /// - Returns: true если ссылка уже обрабатывается
    func isProcessing(link: String) -> Bool {
        return processingLinks.contains(link)
    }
    
    /// Добавляет ссылку в список обрабатываемых
    func addProcessing(link: String) {
        processingLinks.insert(link)
    }
    
    /// Удаляет ссылку из списка обрабатываемых
    func removeProcessing(link: String) {
        processingLinks.remove(link)
    }
}
