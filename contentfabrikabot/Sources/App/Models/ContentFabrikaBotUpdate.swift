import Foundation

struct ContentFabrikaBotUpdate: Codable {
    let update_id: Int
    let message: ContentFabrikaBotMessage?
    let edited_message: ContentFabrikaBotMessage?
    let channel_post: ContentFabrikaBotMessage?
    let callback_query: ContentFabrikaBotCallbackQuery?
    let my_chat_member: ContentFabrikaBotChatMember?
}

struct ContentFabrikaBotMessage: Codable {
    let message_id: Int
    let chat: ContentFabrikaBotChat
    let from: ContentFabrikaBotUser?
    let text: String?
    let caption: String?  // Подпись к фото/видео
    let date: Int?
    let forward_from_chat: ContentFabrikaBotChat?
}

struct ContentFabrikaBotChat: Codable {
    let id: Int64
    let type: String?
    let title: String?
    let username: String?
}

struct ContentFabrikaBotUser: Codable {
    let id: Int64
    let is_bot: Bool?
    let first_name: String?
    let username: String?
}

struct ContentFabrikaBotCallbackQuery: Codable {
    let id: String
    let from: ContentFabrikaBotUser
    let message: ContentFabrikaBotMessage?
    let data: String?
}

struct ContentFabrikaBotChatMember: Codable {
    let chat: ContentFabrikaBotChat
    let from: ContentFabrikaBotUser
    let new_chat_member: ContentFabrikaBotChatMemberStatus
}

struct ContentFabrikaBotChatMemberStatus: Codable {
    let status: String
}

