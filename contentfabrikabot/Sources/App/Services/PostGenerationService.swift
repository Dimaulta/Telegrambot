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
        
        // Обертываем текст в моноширинный формат (используем HTML тег <pre>)
        // Экранируем специальные символы HTML
        let escapedText = generatedPost
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let monospaceText = "<pre>\(escapedText)</pre>"
        
        // Сначала отправляем только готовый текст поста в моноширинном формате
        _ = try await TelegramService.sendMessage(
            token: token,
            chatId: chatId,
            text: monospaceText,
            client: req.client,
            parseMode: "HTML"
        )
        
        // Затем отправляем напоминание и кнопки действий
        let channelTitle = channel.telegramChatTitle ?? "Канал \(channel.telegramChatId)"
        let keyboard = KeyboardService.createPostResultKeyboardWithBack()
        _ = try await TelegramService.sendMessageWithKeyboard(
            token: token,
            chatId: chatId,
            text: "✅ Пост для канала \"\(channelTitle)\" готов!\n\nТапни по тексту выше и он скопируется. Затем опубликуй его вручную от имени канала. Можешь добавить медиа или поправить формулировки перед публикацией.",
            keyboard: keyboard,
            client: req.client
        )
        
               // Очищаем сохраненную тему после успешной генерации
               // Канал уже очищен в контроллере перед генерацией
               await TopicSessionManager.shared.clearTopic(userId: userId)
    }
}

