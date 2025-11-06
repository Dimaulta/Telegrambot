import Foundation

struct NowmttBotUpdate: Codable {
    let update_id: Int
    let message: NowmttMessage?
}

struct NowmttMessage: Codable {
    let message_id: Int
    let chat: NowmttChat
    let text: String?
}

struct NowmttChat: Codable {
    let id: Int64
}

