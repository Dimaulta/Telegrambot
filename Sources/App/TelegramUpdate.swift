import Vapor

public struct TelegramUpdate: Codable {
    public let update_id: Int
    public let message: TelegramMessage?
}

public struct TelegramMessage: Codable {
    public let message_id: Int
    public let from: TelegramUser
    public let chat: Chat
    public let date: Int
    public let video: TelegramVideo?
    public let text: String? // Добавляем поле text
    public let entities: [MessageEntity]?
}

public struct TelegramUser: Codable {
    public let id: Int64
    public let is_bot: Bool
    public let first_name: String
    public let username: String?
    public let language_code: String?
}

public struct Chat: Codable, Sendable {
    public let id: Int64
    public let first_name: String?
    public let last_name: String?
    public let username: String?
    public let type: String
}

public struct TelegramVideo: Codable {
    public let file_id: String
    public let file_unique_id: String
    public let duration: Int
    public let width: Int
    public let height: Int
    public let file_name: String?
    public let mime_type: String
    public let file_size: Int?
}

public struct MessageEntity: Codable {
    public let offset: Int
    public let length: Int
    public let type: String
}