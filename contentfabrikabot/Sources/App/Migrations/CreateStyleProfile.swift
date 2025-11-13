import Fluent

struct CreateStyleProfile: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("style_profiles")
            .id()
            .field("channel_id", .uuid, .required, .references("channels", "id", onDelete: .cascade))
            .field("profile_description", .string, .required)
            .field("analyzed_posts_count", .int, .required)
            .field("is_ready", .bool, .required, .sql(.default(false)))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
    }
    
    func revert(on database: Database) async throws {
        try await database.schema("style_profiles").delete()
    }
}

