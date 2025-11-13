import Foundation

actor RateLimiter {
    private let limit: Int
    private let interval: TimeInterval
    private var timestamps: [Int64: [Date]] = [:]
    
    init(limit: Int, interval: TimeInterval) {
        self.limit = limit
        self.interval = interval
    }
    
    func allow(userId: Int64) -> Bool {
        let now = Date()
        var history = timestamps[userId, default: []].filter { now.timeIntervalSince($0) < interval }
        
        guard history.count < limit else {
            timestamps[userId] = history
            return false
        }
        
        history.append(now)
        timestamps[userId] = history
        return true
    }
}

