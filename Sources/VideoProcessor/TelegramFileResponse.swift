import Vapor

public struct TelegramFileResponse: Codable, Sendable {
    public struct Result: Codable, Sendable {
        public let file_path: String
    }
    
    public let ok: Bool
    public let result: Result
}