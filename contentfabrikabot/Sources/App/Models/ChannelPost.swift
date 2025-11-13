import Fluent
import Vapor

final class ChannelPost: Model, Content, @unchecked Sendable {
    static let schema = "channel_posts"
    
    @ID(key: .id)
    var id: UUID?
    
    @Parent(key: "channel_id")
    var channel: Channel
    
    @Field(key: "telegram_message_id")
    var telegramMessageId: Int
    
    @Field(key: "text")
    var text: String
    
    @Field(key: "post_date")
    var postDate: Int
    
    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?
    
    init() {}
    
    init(id: UUID? = nil, channelID: UUID, telegramMessageId: Int, text: String, postDate: Int) {
        self.id = id
        self.$channel.id = channelID
        self.telegramMessageId = telegramMessageId
        self.text = text
        self.postDate = postDate
    }
}

