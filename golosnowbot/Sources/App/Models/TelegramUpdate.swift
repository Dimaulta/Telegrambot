import Vapor

struct TelegramUpdate: Content, Sendable {
    let update_id: Int
    let message: TelegramMessage?
}

struct TelegramMessage: Content, Sendable {
    let message_id: Int
    let chat: TelegramChat
    let text: String?
}

struct TelegramChat: Content, Sendable {
    let id: Int64
    let type: String
}

