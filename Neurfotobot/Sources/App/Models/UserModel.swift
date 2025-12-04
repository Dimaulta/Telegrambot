import Fluent
import Vapor

final class UserModel: Model, Content, @unchecked Sendable {
    static let schema = "user_models"
    
    @ID(key: .id)
    var id: UUID?
    
    @Field(key: "chat_id")
    var chatId: Int64
    
    @Field(key: "model_version")
    var modelVersion: String
    
    @Field(key: "trigger_word")
    var triggerWord: String
    
    @Field(key: "training_id")
    var trainingId: String?
    
    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?
    
    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?
    
    init() {}
    
    init(id: UUID? = nil, chatId: Int64, modelVersion: String, triggerWord: String, trainingId: String? = nil) {
        self.id = id
        self.chatId = chatId
        self.modelVersion = modelVersion
        self.triggerWord = triggerWord
        self.trainingId = trainingId
    }
}

