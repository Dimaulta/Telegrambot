import Fluent
import Vapor

final class Channel: Model, Content, @unchecked Sendable {
    static let schema = "channels"
    
    @ID(key: .id)
    var id: UUID?
    
    @Field(key: "telegram_chat_id")
    var telegramChatId: Int64
    
    @Field(key: "telegram_chat_title")
    var telegramChatTitle: String?
    
    @Field(key: "owner_user_id")
    var ownerUserId: Int64
    
    @Field(key: "is_active")
    var isActive: Bool
    
    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?
    
    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?
    
    init() {}
    
    init(id: UUID? = nil, telegramChatId: Int64, telegramChatTitle: String?, ownerUserId: Int64, isActive: Bool = true) {
        self.id = id
        self.telegramChatId = telegramChatId
        self.telegramChatTitle = telegramChatTitle
        self.ownerUserId = ownerUserId
        self.isActive = isActive
    }
}

