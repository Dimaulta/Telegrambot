import Fluent

struct CreateChannelPost: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("channel_posts")
            .id()
            .field("channel_id", .uuid, .required, .references("channels", "id", onDelete: .cascade))
            .field("telegram_message_id", .int, .required)
            .field("text", .string, .required)
            .field("post_date", .int, .required)
            .field("created_at", .datetime)
            .unique(on: "channel_id", "telegram_message_id")
            .create()
    }
    
    func revert(on database: Database) async throws {
        try await database.schema("channel_posts").delete()
    }
}

