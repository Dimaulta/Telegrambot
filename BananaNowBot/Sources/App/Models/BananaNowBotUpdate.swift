import Foundation

struct BananaNowBotUpdate: Codable {
    let update_id: Int
    let message: BananaNowBotMessage?
    let edited_message: BananaNowBotMessage?
}

struct BananaNowBotMessage: Codable {
    let message_id: Int
    let chat: BananaNowBotChat
    let text: String?
    let photo: [BananaNowBotPhotoSize]?
    let document: BananaNowBotDocument?
}

struct BananaNowBotChat: Codable {
    let id: Int64
}

struct BananaNowBotPhotoSize: Codable {
    let file_id: String
    let file_unique_id: String
    let width: Int
    let height: Int
}

struct BananaNowBotDocument: Codable {
    let file_id: String?
    let mime_type: String?
}


