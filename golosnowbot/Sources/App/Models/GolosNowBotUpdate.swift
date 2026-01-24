import Vapor

struct GolosNowBotUpdate: Content {
    let update_id: Int
    let message: TelegramMessage?
    let edited_message: TelegramMessage?
}

struct TelegramMessage: Content {
    let message_id: Int
    let date: Int?
    let chat: TelegramChat
    let from: TelegramUser?
    let text: String?
    let voice: TelegramVoice?
    let audio: TelegramAudio?
    
    enum CodingKeys: String, CodingKey {
        case message_id
        case date
        case chat
        case from
        case text
        case voice
        case audio
    }
}

struct TelegramChat: Content {
    let id: Int64
}

struct TelegramUser: Content {
    let id: Int64
    let first_name: String?
    let last_name: String?
    let username: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case first_name
        case last_name
        case username
    }
}

struct TelegramVoice: Content {
    let file_id: String
    let file_unique_id: String?
    let duration: Int?
    let mime_type: String?
    let file_size: Int?
    
    enum CodingKeys: String, CodingKey {
        case file_id
        case file_unique_id
        case duration
        case mime_type
        case file_size
    }
}

struct TelegramAudio: Content {
    let file_id: String
    let file_unique_id: String?
    let duration: Int?
    let performer: String?
    let title: String?
    let mime_type: String?
    let file_size: Int?
    
    enum CodingKeys: String, CodingKey {
        case file_id
        case file_unique_id
        case duration
        case performer
        case title
        case mime_type
        case file_size
    }
}

struct TelegramFileResponse: Content {
    let ok: Bool
    let result: TelegramFile?
    let description: String?
    let error_code: Int?
}

struct TelegramFile: Content {
    let file_id: String
    let file_unique_id: String?
    let file_size: Int?
    let file_path: String?
    
    enum CodingKeys: String, CodingKey {
        case file_id
        case file_unique_id
        case file_size
        case file_path
    }
}
