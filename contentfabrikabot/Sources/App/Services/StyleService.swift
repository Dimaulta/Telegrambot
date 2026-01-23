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
    ///   - backCallback: Callback для кнопки "Назад" (по умолчанию "back_to_main")
    static func analyzeChannel(
        userId: Int64,
        token: String,
        req: Request,
        isRelearn: Bool,
        channelId: String? = nil,
        replyToMessageId: Int? = nil,
        backCallback: String = "back_to_main"
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
            let chatId = TelegramService.getChatIdFromUserId(userId: userId)
            _ = try await TelegramService.sendMessage(
                token: token,
                chatId: chatId,
                text: "❌ Я ещё не знаю твой канал.\n\nПерешли мне от 3 до 10 постов через Forward, и я смогу изучить стиль.",
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
        
        // Фильтруем посты с текстом (исключаем маркер "[Медиа без текста]")
        let postsWithText = savedPosts.filter { PostService.hasText($0) }
        
        // Получаем статистику для более информативных сообщений
        let stats = try await PostService.getPostsStatistics(
            channelId: try channel.requireID(),
            db: req.db
        )
        
        if savedPosts.isEmpty {
            // Нет сохраненных постов - просим пользователя переслать посты
            let chatId = TelegramService.getChatIdFromUserId(userId: userId)
            let instructionMessage = """
❌ В базе данных нет постов из твоего канала.

📝 Что нужно сделать:

1. Открой свой канал в Telegram
2. Выбери от 3 до 10 публикаций
3. Перешли их мне в этот чат (Forward из канала, не копируй текст)

⚠️ Как только я получу минимум 3 поста с текстом, кнопка «Изучить канал» станет активной.
"""
            try await TelegramService.sendMessage(
                token: token,
                chatId: chatId,
                text: instructionMessage,
                client: req.client,
                replyToMessageId: replyToMessageId
            )
            return
        }
        
        // Проверяем, есть ли уже изученный стиль
        let channelId = try channel.requireID()
        let currentProfile = try await StyleService.getStyleProfile(channelId: channelId, db: req.db)
        
        // Если стиль уже изучен и это не переобучение, проверяем, были ли новые посты
        if let profile = currentProfile, !isRelearn {
            // Получаем количество постов, которые были проанализированы
            let analyzedPostsCount = profile.analyzedPostsCount
            
            // Если количество постов с текстом не изменилось, стиль уже изучен
            if postsWithText.count <= analyzedPostsCount {
                let chatId = TelegramService.getChatIdFromUserId(userId: userId)
                let keyboard = KeyboardService.createGeneratePostKeyboardWithBack()
                let message = "✅ Стиль твоего канала уже изучен на основе \(KeyboardService.pluralizePost(analyzedPostsCount)) с текстом.\n\nОтправь мне тему или несколько тезисов и я пришлю готовый пост в твоём стиле, который ты сможешь вручную опубликовать в канале"
                try await TelegramService.sendMessageWithKeyboard(
                    token: token,
                    chatId: chatId,
                    text: message,
                    keyboard: keyboard,
                    client: req.client,
                    replyToMessageId: replyToMessageId
                )
                return
            }
        }
        
        // Проверяем минимальное количество постов С ТЕКСТОМ для анализа
        let minPostsWithTextRequired = 3
        if postsWithText.count < minPostsWithTextRequired {
            let chatId = TelegramService.getChatIdFromUserId(userId: userId)
            var errorMessage = "❌ Недостаточно постов с текстом\n\n"
            errorMessage += "У тебя сохранено \(KeyboardService.pluralizePost(stats.total)), но только \(KeyboardService.pluralizePost(stats.withText)) из них содержат текст.\n\n"
            errorMessage += "Для изучения стиля нужно минимум 3 поста с текстом или подписью к медиа.\n\n"
            
            if stats.mediaOnly > 0 {
                errorMessage += "⚠️ Обрати внимание: \(KeyboardService.pluralizePost(stats.mediaOnly)) из твоих постов содержат только медиа без подписи. Такие посты не помогут мне понять стиль написания.\n\n"
            }
            
            errorMessage += "Перешли еще посты с текстом, и кнопка «Изучить канал» станет активной."
            
            let keyboard = KeyboardService.createBackCancelKeyboard(backCallback: backCallback)
            try await TelegramService.sendMessageWithKeyboard(
                token: token,
                chatId: chatId,
                text: errorMessage,
                keyboard: keyboard,
                client: req.client,
                replyToMessageId: replyToMessageId
            )
            return
        }
        
        // Проверяем минимальное количество постов для анализа (предупреждение, но продолжаем)
        let minPostsRequired = 3
        if postsWithText.count < minPostsRequired {
            // Мало постов - предупреждаем, но все равно анализируем
            let chatId = TelegramService.getChatIdFromUserId(userId: userId)
            try await TelegramService.sendMessage(
                token: token,
                chatId: chatId,
                text: "⚠️ В твоём канале найдено только \(KeyboardService.pluralizePost(postsWithText.count)) с текстом. Для лучшего изучения стиля рекомендуется минимум \(minPostsRequired) поста.\n\nЯ проанализирую то, что есть, но результат может быть менее точным. Рекомендую добавить больше постов с текстом в канал и переизучить стиль позже.",
                client: req.client,
                replyToMessageId: replyToMessageId
            )
        }
        
        // Анализируем стиль только по постам с текстом
        let postTexts = postsWithText.map { $0.text }
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
            profile.analyzedPostsCount = postsWithText.count
            profile.isReady = true
            try await profile.update(on: req.db)
        } else {
            // Создаем новый профиль
            let profile = StyleProfile(
                channelID: try channel.requireID(),
                profileDescription: styleProfile,
                analyzedPostsCount: postsWithText.count,
                isReady: true
            )
            try await profile.save(on: req.db)
        }
        
        let successMessage = isRelearn 
            ? "✅ Стиль твоего канала переизучен на основе \(postsWithText.count) постов с текстом\n\nТеперь отправь мне тему и я подготовлю текст в твоём стиле, ты сможешь скопировать его у себя в чате"
            : "✅ Стиль твоего канала изучен на основе \(postsWithText.count) постов с текстом\n\nОтправь мне тему или несколько тезисов и я пришлю готовый пост в твоём стиле, который ты сможешь вручную опубликовать в канале"
        
        // Добавляем кнопки для быстрого создания нового поста и удаления данных с кнопкой "Назад"
        let keyboard = KeyboardService.createGeneratePostKeyboardWithBack(totalCount: stats.total)
        
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

