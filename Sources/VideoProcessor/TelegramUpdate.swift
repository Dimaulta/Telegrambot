import Vapor

public struct TelegramUpdate: Content {
    public var message: TelegramMessage?
    
    public init(message: TelegramMessage? = nil) {
        self.message = message
    }
}

public struct TelegramMessage: Content {
    public var chat: Chat
    public var video: TelegramVideo?
    
    public init(chat: Chat, video: TelegramVideo? = nil) {
        self.chat = chat
        self.video = video
    }
}

public struct Chat: Content {
    public var id: Int64
    
    public init(id: Int64) {
        self.id = id
    }
}

public struct TelegramVideo: Content {
    public var fileId: String
    
    public init(fileId: String) {
        self.fileId = fileId
    }
}