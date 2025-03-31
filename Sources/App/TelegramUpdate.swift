import Vapor

struct TelegramUpdate: Content {
    var update_id: Int
    var message: TelegramMessage?
}

struct TelegramMessage: Content {
    var message_id: Int
    var from: TelegramUser
    var chat: Chat
    var date: Int
    var video: TelegramVideo?
}

struct TelegramUser: Content {
    var id: Int64
    var is_bot: Bool
    var first_name: String
    var username: String?
    var language_code: String?
    var is_premium: Bool?
}

struct Chat: Content {
    var id: Int64
    var first_name: String
    var username: String?
    var type: String
}

struct TelegramVideo: Content {
    var duration: Int
    var width: Int
    var height: Int
    var file_name: String
    var mime_type: String
    var file_id: String
    var file_size: Int?
    var thumbnail: TelegramPhotoSize?
}

struct TelegramPhotoSize: Content {
    var file_id: String
    var file_unique_id: String
    var width: Int
    var height: Int
    var file_size: Int?
}