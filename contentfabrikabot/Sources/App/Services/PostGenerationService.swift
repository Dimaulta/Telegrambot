import Vapor
import Fluent
import Foundation

/// Сервис для генерации и публикации постов
struct PostGenerationService {
    
    /// Найти изображение в папке img проекта
    /// - Returns: Путь к файлу изображения или nil, если не найдено
    static func findPlaceholderImage() -> String? {
        let imgPath = "img"
        
        // Проверяем существование папки (должна быть создана в configure.swift)
        guard FileManager.default.fileExists(atPath: imgPath) else {
            return nil
        }
        
        // Получаем список файлов в папке
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: imgPath),
              !files.isEmpty else {
            // Папка существует, но пустая - это нормально
            return nil
        }
        
        // Поддерживаемые форматы изображений
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "webp"]
        
        // Ищем первый подходящий файл
        for file in files {
            let filePath = "\(imgPath)/\(file)"
            let fileExtension = (file as NSString).pathExtension.lowercased()
            
            // Пропускаем скрытые файлы и системные файлы
            if file.hasPrefix(".") {
                continue
            }
            
            // Проверяем расширение
            guard imageExtensions.contains(fileExtension) else {
                continue
            }
            
            // Проверяем размер файла (до 1 МБ = 1024 * 1024 байт)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: filePath),
               let fileSize = attributes[.size] as? Int64,
               fileSize > 0, // Файл не пустой
               fileSize <= 1024 * 1024 {
                return filePath
            }
        }
        
        return nil
    }
    
    /// Сгенерировать пост для пользователя и опубликовать его
    /// - Parameters:
    ///   - topic: Тема поста
    ///   - styleProfile: Профиль стиля канала
    ///   - channel: Канал
    ///   - userId: ID пользователя
    ///   - token: Токен бота
    ///   - req: Request объект
    ///   - withPhoto: Если true, отправляет пост с фото (аватарка канала). По умолчанию true
    static func generateAndPublishPost(
        topic: String,
        styleProfile: StyleProfile,
        channel: Channel,
        userId: Int64,
        token: String,
        req: Request,
        withPhoto: Bool = true
    ) async throws {
        let openAIService = try OpenAIStyleService(request: req)
        
        let chatId = TelegramService.getChatIdFromUserId(userId: userId)
        try await TelegramService.sendMessage(
            token: token,
            chatId: chatId,
            text: "Генерирую пост в твоём стиле... ✨",
            client: req.client
        )
        
        let generatedPost = try await openAIService.generatePost(
            topic: topic,
            styleProfile: styleProfile.profileDescription
        )
        
        // Telegram ограничивает caption для фото до 1024 символов
        // Если текст длиннее и мы хотим отправить с фото - отправляем без фото
        let telegramCaptionLimit = 1024
        let shouldSendWithPhoto = withPhoto && generatedPost.count <= telegramCaptionLimit
        
        if withPhoto && generatedPost.count > telegramCaptionLimit {
            req.logger.info("⚠️ Generated post is too long (\(generatedPost.count) chars) for photo caption (limit: \(telegramCaptionLimit)). Sending as text-only post.")
        }
        
        // Сразу публикуем пост в отложенные публикации канала
        try await publishToScheduled(
            channelId: channel.telegramChatId,
            text: generatedPost,
            token: token,
            userId: userId,
            req: req,
            withPhoto: shouldSendWithPhoto
        )
    }
    
    /// Опубликовать пост в отложенные публикации (через 24 часа)
    /// - Parameters:
    ///   - channelId: ID канала в Telegram
    ///   - text: Текст поста
    ///   - token: Токен бота
    ///   - userId: ID пользователя
    ///   - req: Request объект
    ///   - withPhoto: Если true, отправляет пост с фото (заглушкой). Если false - только текст
    static func publishToScheduled(
        channelId: Int64,
        text: String,
        token: String,
        userId: Int64,
        req: Request,
        withPhoto: Bool = false
    ) async throws {
        // Публикуем пост в отложенные публикации (через 24 часа, чтобы автор успел отредактировать)
        // Telegram требует минимум 60 секунд в будущем, мы ставим 24 часа
        let currentTime = Int(Date().timeIntervalSince1970)
        let scheduleDate = currentTime + 86400 // через 24 часа (сутки)
        
        req.logger.info("📅 Scheduling post for channel \(channelId) at timestamp \(scheduleDate) (current: \(currentTime), delay: 24 hours), withPhoto: \(withPhoto)")
        
        do {
            let response: ClientResponse
            
            if withPhoto {
                // Отправляем пост с фото
                // Приоритет: 1) URL из переменной окружения, 2) Локальный файл из папки img, 3) Реальный placeholder URL
                var photoToUse: String? = Environment.get("CONTENTFABRIKABOT_PLACEHOLDER_PHOTO_URL")
                var isLocalFile = false
                
                // Если URL не задан, ищем локальный файл
                if photoToUse == nil {
                    if let localImagePath = findPlaceholderImage() {
                        photoToUse = localImagePath
                        isLocalFile = true
                        req.logger.info("📸 Using local image from img folder: \(localImagePath)")
                    } else {
                        // Используем реальный URL с безопасным изображением из Unsplash Source
                        // Unsplash Source предоставляет бесплатные изображения без API ключа
                        // Используем случайное изображение природы/леса (безопасное и красивое)
                        photoToUse = "https://source.unsplash.com/1200x630/?nature,forest,trees"
                        req.logger.info("📸 Using Unsplash Source placeholder URL (nature/forest)")
                    }
                } else {
                    req.logger.info("📸 Using placeholder photo URL from env: \(photoToUse!)")
                }
                
                response = try await TelegramService.sendScheduledPhoto(
                    token: token,
                    chatId: channelId,
                    photo: photoToUse!,
                    caption: text,
                    scheduleDate: scheduleDate,
                    req: req,
                    isLocalFile: isLocalFile
                )
            } else {
                // Отправляем только текст
                response = try await TelegramService.sendScheduledMessage(
                    token: token,
                    chatId: channelId,
                    text: text,
                    scheduleDate: scheduleDate,
                    req: req
                )
            }
            
            // Логируем ответ от Telegram API
            let responseBody = response.body?.getString(at: 0, length: response.body?.readableBytes ?? 0, encoding: .utf8) ?? ""
            req.logger.info("📥 Telegram API response: status=\(response.status), body=\(responseBody.prefix(500))")
            
            if response.status == .ok {
                // Проверяем, действительно ли сообщение запланировано
                // В ответе должен быть schedule_date или message с date в будущем
                let isScheduled = responseBody.contains("schedule_date") || 
                                 responseBody.contains("\"schedule_date\"") ||
                                 responseBody.contains("\"ok\":true")
                
                if isScheduled {
                    req.logger.info("✅ Post successfully scheduled for channel \(channelId)")
                    
                    // НЕ сохраняем пост в БД здесь - он будет сохранен автоматически
                    // когда придет webhook channel_post от Telegram
                    // Это предотвращает дублирование и ошибку UNIQUE constraint
                    
                    let chatId = TelegramService.getChatIdFromUserId(userId: userId)
                    
                    // Создаем кнопки для быстрых действий
                    let keyboard = KeyboardService.createRelearnKeyboard()
                    
                    try await TelegramService.sendMessageWithKeyboard(
                        token: token,
                        chatId: chatId,
                        text: "✅ Пост сгенерирован и добавлен в отложенные публикации твоего канала\n\n📝 Пост будет автоматически опубликован через 24 часа\n\n💡 Ты можешь отредактировать пост в отложенных публикациях канала до момента публикации. Открой настройки канала → Отложенные записи, чтобы увидеть и отредактировать пост",
                        keyboard: keyboard,
                        client: req.client
                    )
                } else {
                    // Пост опубликован сразу, а не запланирован
                    req.logger.warning("⚠️ Post was published immediately instead of being scheduled. Response: \(responseBody)")
                    
                    let chatId = TelegramService.getChatIdFromUserId(userId: userId)
                    let keyboard = InlineKeyboardMarkup(inline_keyboard: [
                        [
                            InlineKeyboardButton(text: "🔄 Переизучить канал", callback_data: "relearn_style")
                        ],
                        [
                            InlineKeyboardButton(text: "🗑️ Удалить все данные", callback_data: "reset_all_data")
                        ]
                    ])
                    
                    try await TelegramService.sendMessageWithKeyboard(
                        token: token,
                        chatId: chatId,
                        text: "⚠️ Пост был опубликован сразу, а не в отложенные публикации. Возможно, бот не имеет прав администратора или параметр schedule_date не был применен. Проверь права бота в канале",
                        keyboard: keyboard,
                        client: req.client
                    )
                }
            } else {
                req.logger.error("❌ Failed to schedule post to channel: \(response.status) - \(responseBody)")
                
                let chatId = TelegramService.getChatIdFromUserId(userId: userId)
                try await TelegramService.sendMessage(
                    token: token,
                    chatId: chatId,
                    text: "❌ Ошибка при создании поста. Убедись, что бот является администратором канала с правом публикации",
                    client: req.client
                )
            }
        } catch {
            req.logger.error("Error scheduling post: \(error)")
            let chatId = TelegramService.getChatIdFromUserId(userId: userId)
            try await TelegramService.sendMessage(
                token: token,
                chatId: chatId,
                text: "❌ Ошибка при создании поста: \(error.localizedDescription)",
                client: req.client
            )
        }
    }
    
    /// Опубликовать пост сразу в канал (не используется, но оставлено для совместимости)
    static func publishToChannel(
        channelId: Int64,
        text: String,
        token: String,
        userId: Int64,
        req: Request
    ) async throws {
        // Этот метод не используется, т.к. мы публикуем только в отложенные публикации
        // Оставлен для возможного будущего использования
        req.logger.warning("publishToChannel called but not implemented - use publishToScheduled instead")
    }
}

