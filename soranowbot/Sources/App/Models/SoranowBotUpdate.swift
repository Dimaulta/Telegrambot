import Foundation

struct SoranowBotUpdate: Codable {
    let update_id: Int
    let message: SoranowMessage?
}

struct SoranowMessage: Codable {
    let message_id: Int
    let chat: SoranowChat
    let text: String?
}

struct SoranowChat: Codable {
    let id: Int64
}
