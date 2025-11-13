import Vapor
import Fluent

/// Сервис для генерации постов и отправки пользователю
struct PostGenerationService {
    
    static func generatePostForUser(
        topic: String,
        styleProfile: StyleProfile,
        channel: Channel,
        userId: Int64,
        token: String,
        req: Request
    ) async throws {
        let openAIService = try OpenAIStyleService(request: req)
        let generatedPost = try await openAIService.generatePost(
            topic: topic,
            styleProfile: styleProfile.profileDescription
        )
        
        let chatId = TelegramService.getChatIdFromUserId(userId: userId)
        
        // Сначала отправляем только готовый текст поста
        _ = try await TelegramService.sendMessage(
            token: token,
            chatId: chatId,
            text: generatedPost,
            client: req.client
        )
        
        // Затем отправляем напоминание и кнопки действий
        let keyboard = KeyboardService.createPostResultKeyboard()
        _ = try await TelegramService.sendMessageWithKeyboard(
            token: token,
            chatId: chatId,
            text: "📌 Скопируй текст и опубликуй его вручную от имени канала. Можешь добавить медиа или поправить формулировки перед публикацией.",
            keyboard: keyboard,
            client: req.client
        )
    }
}

