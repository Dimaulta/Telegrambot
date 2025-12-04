import Fluent

struct CreateUserModel: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("user_models")
            .id()
            .field("chat_id", .int64, .required)
            .field("model_version", .string, .required)
            .field("trigger_word", .string, .required)
            .field("training_id", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "chat_id") // Один пользователь - одна модель
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("user_models").delete()
    }
}

