import Foundation

struct NowControllerBotUpdate: Codable {
    let update_id: Int
    let message: NowControllerMessage?
}

struct NowControllerMessage: Codable {
    let message_id: Int
    let chat: NowControllerChat
    let text: String?
}

struct NowControllerChat: Codable {
    let id: Int64
}
