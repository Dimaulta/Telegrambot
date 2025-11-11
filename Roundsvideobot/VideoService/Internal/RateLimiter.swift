import Foundation

actor RateLimiter {
    static let shared = RateLimiter(limit: 2, windowSeconds: 60)
    
    private let limit: Int
    private let window: TimeInterval
    private var keyToTimestamps: [String: [Date]] = [:]
    
    init(limit: Int, windowSeconds: TimeInterval) {
        self.limit = limit
        self.window = windowSeconds
    }
    
    func allow(key: String) -> Bool {
        let now = Date()
        var timestamps = (keyToTimestamps[key] ?? []).filter { now.timeIntervalSince($0) < window }
        if timestamps.count >= limit {
            keyToTimestamps[key] = timestamps
            return false
        }
        timestamps.append(now)
        keyToTimestamps[key] = timestamps
        return true
    }
    
    func secondsUntilReset(key: String) -> Int {
        let now = Date()
        let timestamps = (keyToTimestamps[key] ?? []).filter { now.timeIntervalSince($0) < window }
        guard timestamps.count >= limit, let first = timestamps.first else { return 0 }
        let remaining = window - now.timeIntervalSince(first)
        return max(0, Int(ceil(remaining)))
    }
}

