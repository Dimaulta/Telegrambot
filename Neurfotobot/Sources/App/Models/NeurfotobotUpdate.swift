import Foundation

struct NeurfotobotUpdate: Codable {
    let update_id: Int
    let message: NeurfotobotMessage?
    let callback_query: NeurfotobotCallbackQuery?
}

struct NeurfotobotMessage: Codable {
    let message_id: Int
    let chat: NeurfotobotChat
    let text: String?
    let photo: [NeurfotobotPhoto]?
}

struct NeurfotobotChat: Codable {
    let id: Int64
}

struct NeurfotobotPhoto: Codable {
    let file_id: String
    let file_unique_id: String
    let file_size: Int?
    let width: Int
    let height: Int
}

struct NeurfotobotCallbackQuery: Codable {
    let id: String
    let from: NeurfotobotUser
    let message: NeurfotobotMessage?
    let data: String?
}

struct NeurfotobotUser: Codable {
    let id: Int64
    let is_bot: Bool?
    let first_name: String?
    let username: String?
}