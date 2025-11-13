import Vapor
import Fluent

/// Сервис для работы со стилями каналов
struct StyleService {
    
    /// Анализировать стиль канала пользователя
    /// - Parameters:
    ///   - userId: ID пользователя
    ///   - token: Токен бота
    ///   - req: Request объект
    ///   - isRelearn: Флаг переобучения
    ///   - channelId: Опциональный ID канала (UUID в строковом формате). Если не указан, используется первый канал пользователя
    ///   - replyToMessageId: ID сообщения для reply (опционально)
    static func analyzeChannel(
        userId: Int64,
        token: String,
        req: Request,
        isRelearn: Bool,
        channelId: String? = nil,
        replyToMessageId: Int? = nil
    ) async throws {
        // Находим каналы пользователя
        var channel: Channel?
        
        if let channelIdString = channelId, let channelUUID = UUID(uuidString: channelIdString) {
            // Ищем конкретный канал по ID
            channel = try await Channel.query(on: req.db)
                .filter(\.$id == channelUUID)
                .filter(\.$ownerUserId == userId)
                .filter(\.$isActive == true)
                .first()
        } else {
            // Используем первый канал пользователя
            let channels = try await Channel.query(on: req.db)
                .filter(\.$ownerUserId == userId)
                .filter(\.$isActive == true)
                .all()
            channel = channels.first
        }
        
        guard let channel = channel else {
            // Нет канала - просим добавить бота
            let chatId = TelegramService.getChatIdFromUserId(userId: userId)
            _ = try await TelegramService.sendMessage(
                token: token,
                chatId: chatId,
                text: "❌ Не найден активный канал.\n\nДобавь меня в свой канал как администратора с правом публикации, затем перешли мне посты из канала.",
                client: req.client,
                replyToMessageId: replyToMessageId
            )
            return
        }
        
        // Получаем последние посты из БД (максимум 10)
        let savedPosts = try await PostService.getRecentPosts(
            channelId: try channel.requireID(),
            limit: 10,
            db: req.db
        )
        
        if savedPosts.isEmpty {
            // Нет сохраненных постов - просим пользователя переслать посты
            let chatId = TelegramService.getChatIdFromUserId(userId: userId)
            let instructionMessage = """
❌ В базе данных нет постов из твоего канала.

📝 Что нужно сделать:

1. Открой свой канал в Telegram
2. Выбери 5-10 последних постов
3. Перешли их мне в этот чат (Forward из канала)

⚠️ Важно: Пересылай посты через Forward, а не копируй текст!

После того как я получу минимум 3 поста, кнопка "Изучить канал" появится автоматически.

💡 После того как я стану админом канала, я буду автоматически сохранять все новые посты.
"""
            try await TelegramService.sendMessage(
                token: token,
                chatId: chatId,
                text: instructionMessage,
                client: req.client
            )
            return
        }
        
        // Проверяем минимальное количество постов для анализа
        let minPostsRequired = 3
        if savedPosts.count < minPostsRequired {
            // Мало постов - предупреждаем, но все равно анализируем
            let chatId = TelegramService.getChatIdFromUserId(userId: userId)
            try await TelegramService.sendMessage(
                token: token,
                chatId: chatId,
                text: "⚠️ В твоём канале найдено только \(savedPosts.count) пост(а). Для лучшего изучения стиля рекомендуется минимум \(minPostsRequired) поста.\n\nЯ проанализирую то, что есть, но результат может быть менее точным. Рекомендую добавить больше постов в канал и переизучить стиль позже.",
                client: req.client
            )
        }
        
        // Анализируем стиль
        let postTexts = savedPosts.map { $0.text }
        let openAIService = try OpenAIStyleService(request: req)
        
        let chatId = TelegramService.getChatIdFromUserId(userId: userId)
        let message = isRelearn ? "Переизучаю стиль твоего канала..." : "Анализирую стиль твоего канала..."
        try await TelegramService.sendMessage(
            token: token,
            chatId: chatId,
            text: "\(message) Это может занять несколько секунд ⏳",
            client: req.client
        )
        
        let styleProfile = try await openAIService.analyzeStyle(posts: postTexts)
        
        // Обновляем или создаем профиль стиля
        let existingProfile = try await StyleProfile.query(on: req.db)
            .filter(\.$channel.$id == channel.requireID())
            .first()
        
        if let profile = existingProfile {
            // Обновляем существующий профиль
            profile.profileDescription = styleProfile
            profile.analyzedPostsCount = savedPosts.count
            profile.isReady = true
            try await profile.update(on: req.db)
        } else {
            // Создаем новый профиль
            let profile = StyleProfile(
                channelID: try channel.requireID(),
                profileDescription: styleProfile,
                analyzedPostsCount: savedPosts.count,
                isReady: true
            )
            try await profile.save(on: req.db)
        }
        
        let successMessage = isRelearn 
            ? "✅ Стиль твоего канала переизучен на основе последних \(savedPosts.count) постов\n\nТеперь отправь мне тему для поста, и я автоматически сгенерирую его в твоём стиле\n\n💡 Пост будет добавлен в отложенные публикации канала и автоматически опубликован через 24 часа. Ты сможешь отредактировать его в отложенных публикациях до момента публикации"
            : "✅ Стиль твоего канала изучен на основе \(savedPosts.count) постов\n\nТеперь отправь мне тему для поста, и я автоматически сгенерирую его в твоём стиле 📝\n\n💡 Пост будет добавлен в отложенные публикации канала и автоматически опубликован через 24 часа. Ты сможешь отредактировать его в отложенных публикациях до момента публикации"
        
        // Добавляем кнопки для быстрого создания нового поста и удаления данных
        let keyboard = KeyboardService.createGeneratePostKeyboard()
        
        try await TelegramService.sendMessageWithKeyboard(
            token: token,
            chatId: chatId,
            text: successMessage,
            keyboard: keyboard,
            client: req.client
        )
    }
    
    /// Получить профиль стиля для канала
    static func getStyleProfile(
        channelId: UUID,
        db: Database
    ) async throws -> StyleProfile? {
        return try await StyleProfile.query(on: db)
            .filter(\.$channel.$id == channelId)
            .filter(\.$isReady == true)
            .first()
    }
}

