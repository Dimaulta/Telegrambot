import Foundation

struct WmmoveBotUpdate: Codable {
    let update_id: Int
    let message: WmmoveMessage?
}

struct WmmoveMessage: Codable {
    let message_id: Int
    let chat: WmmoveChat
    let text: String?
}

struct WmmoveChat: Codable {
    let id: Int64
}
