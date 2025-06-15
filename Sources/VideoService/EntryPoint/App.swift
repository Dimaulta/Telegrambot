import Vapor

public struct App {
    public static func run() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)
        
        let app = try await Application.make(env)
        try await configure(app)
        
        try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    try await app.execute()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
} 