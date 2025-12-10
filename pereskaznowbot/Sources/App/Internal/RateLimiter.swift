import Foundation
import NIOCore

actor RateLimiter {
    private var requests: [Int64: [Date]] = [:]
    private let maxRequests: Int
    private let timeWindow: TimeInterval
    
    init(maxRequests: Int = 5, timeWindow: TimeInterval = 60) {
        self.maxRequests = maxRequests
        self.timeWindow = timeWindow
    }
    
    func checkLimit(for userId: Int64) -> Bool {
        let now = Date()
        let windowStart = now.addingTimeInterval(-timeWindow)
        
        // Очищаем старые запросы
        if var userRequests = requests[userId] {
            userRequests.removeAll { $0 < windowStart }
            requests[userId] = userRequests
            
            // Проверяем лимит
            if userRequests.count >= maxRequests {
                return false
            }
        }
        
        // Добавляем текущий запрос
        if requests[userId] == nil {
            requests[userId] = []
        }
        requests[userId]?.append(now)
        
        return true
    }
    
    func reset(for userId: Int64) {
        requests[userId] = []
    }
}
