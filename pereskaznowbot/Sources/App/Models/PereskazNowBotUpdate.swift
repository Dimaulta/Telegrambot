import Foundation

struct PereskazNowBotUpdate: Codable {
    let update_id: Int
    let message: PereskazNowMessage?
}

struct PereskazNowMessage: Codable {
    let message_id: Int
    let chat: PereskazNowChat
    let text: String?
}

struct PereskazNowChat: Codable {
    let id: Int64
}
