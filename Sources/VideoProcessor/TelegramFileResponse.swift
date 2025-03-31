import Vapor

public struct TelegramFileResponse: Codable {
    public struct Result: Codable {
        public let file_path: String
        
        public init(file_path: String) {
            self.file_path = file_path
        }
    }
    public let result: Result
    
    public init(result: Result) {
        self.result = result
    }
}