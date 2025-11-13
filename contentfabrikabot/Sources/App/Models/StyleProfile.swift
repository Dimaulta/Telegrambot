import Fluent
import Vapor

final class StyleProfile: Model, Content, @unchecked Sendable {
    static let schema = "style_profiles"
    
    @ID(key: .id)
    var id: UUID?
    
    @Parent(key: "channel_id")
    var channel: Channel
    
    @Field(key: "profile_description")
    var profileDescription: String
    
    @Field(key: "analyzed_posts_count")
    var analyzedPostsCount: Int
    
    @Field(key: "is_ready")
    var isReady: Bool
    
    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?
    
    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?
    
    init() {}
    
    init(id: UUID? = nil, channelID: UUID, profileDescription: String, analyzedPostsCount: Int, isReady: Bool = false) {
        self.id = id
        self.$channel.id = channelID
        self.profileDescription = profileDescription
        self.analyzedPostsCount = analyzedPostsCount
        self.isReady = isReady
    }
}

