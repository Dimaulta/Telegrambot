import Foundation

struct NeurVideoBotUpdate: Codable {
    let update_id: Int?
    let message: NeurVideoBotMessage?
    let edited_message: NeurVideoBotMessage?
}

struct NeurVideoBotMessage: Codable {
    let message_id: Int?
    let chat: NeurVideoBotChat
    let text: String?
}

struct NeurVideoBotChat: Codable {
    let id: Int64
}

