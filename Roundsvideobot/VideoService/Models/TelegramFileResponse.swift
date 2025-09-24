import Vapor

public struct TelegramFileResponse: Content {
    public struct Result: Content {
        public let file_path: String
    }
    
    public let ok: Bool
    public let result: Result
}