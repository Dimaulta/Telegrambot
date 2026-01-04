import Foundation

struct AntispamNowBotUpdate: Codable {
    let update_id: Int
    let message: AntispamNowBotMessage?
    let edited_message: AntispamNowBotMessage?
}

struct AntispamNowBotMessage: Codable {
    let message_id: Int
    let chat: AntispamNowBotChat
    let text: String?
    let photo: [AntispamNowBotPhotoSize]?
    let document: AntispamNowBotDocument?
}

struct AntispamNowBotChat: Codable {
    let id: Int64
}

struct AntispamNowBotPhotoSize: Codable {
    let file_id: String
    let file_unique_id: String
    let width: Int
    let height: Int
}

struct AntispamNowBotDocument: Codable {
    let file_id: String?
    let mime_type: String?
}


