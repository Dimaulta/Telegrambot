import Foundation

struct TelegramUpdate: Codable {
    let message: TelegramMessage?
}

struct TelegramMessage: Codable {
    let message_id: Int
    let from: TelegramUser
    let chat: TelegramChat
    let date: Int
    let text: String?
    let video: TelegramVideo?
}

struct TelegramUser: Codable {
    let id: Int64
    let is_bot: Bool
    let first_name: String
    let username: String?
}

struct TelegramChat: Codable {
    let id: Int64
    let type: String
    let title: String?
    let username: String?
    let first_name: String?
    let last_name: String?
}

struct TelegramVideo: Codable {
    let file_id: String
    let file_unique_id: String
    let width: Int
    let height: Int
    let duration: Int
    let mime_type: String?
    let file_name: String?
    let file_size: Int?
} 