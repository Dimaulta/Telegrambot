import Foundation

struct SoranowBotUpdate: Codable {
    let update_id: Int?
    let message: SoranowBotMessage?
    let edited_message: SoranowBotMessage?
}

struct SoranowBotMessage: Codable {
    let message_id: Int?
    let chat: SoranowBotChat
    let text: String?
}

struct SoranowBotChat: Codable {
    let id: Int64
}

