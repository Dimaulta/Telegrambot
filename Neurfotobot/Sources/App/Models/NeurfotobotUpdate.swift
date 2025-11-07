import Foundation

struct NeurfotobotUpdate: Codable {
    let update_id: Int
    let message: NeurfotobotMessage?
}

struct NeurfotobotMessage: Codable {
    let message_id: Int
    let chat: NeurfotobotChat
    let text: String?
}

struct NeurfotobotChat: Codable {
    let id: Int64
}