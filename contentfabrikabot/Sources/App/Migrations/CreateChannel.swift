import Fluent

struct CreateChannel: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("channels")
            .id()
            .field("telegram_chat_id", .int64, .required)
            .field("telegram_chat_title", .string)
            .field("owner_user_id", .int64, .required)
            .field("is_active", .bool, .required, .sql(.default(true)))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "telegram_chat_id")
            .create()
    }
    
    func revert(on database: Database) async throws {
        try await database.schema("channels").delete()
    }
}

