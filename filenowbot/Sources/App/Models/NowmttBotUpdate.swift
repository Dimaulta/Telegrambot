import Foundation

struct FileNowBotUpdate: Codable {
    let update_id: Int
    let message: FileNowMessage?
}

struct FileNowMessage: Codable {
    let message_id: Int
    let chat: FileNowChat
    let text: String?
}

struct FileNowChat: Codable {
    let id: Int64
}

