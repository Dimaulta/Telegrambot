import Vapor
import Foundation
import Fluent

/// Actor для thread-safe дедупликации update_id
actor UpdateIdDeduplicator {
    private var processedUpdateIds = Set<Int>()
    private let maxProcessedIds = 1000
    
    func isDuplicate(_ updateId: Int) -> Bool {
        if processedUpdateIds.contains(updateId) {
            return true
        }
        
        // Добавляем в множество обработанных
        processedUpdateIds.insert(updateId)
        
        // Ограничиваем размер множества (удаляем старые, если превышен лимит)
        if processedUpdateIds.count > maxProcessedIds {
            // Удаляем самые старые (просто очищаем и оставляем последние)
            let sortedIds = Array(processedUpdateIds.sorted().suffix(maxProcessedIds / 2))
            processedUpdateIds = Set(sortedIds)
        }
        
        return false
    }
}

/// Actor для отслеживания последовательных постов без текста
actor MediaOnlyPostsTracker {
    private var userConsecutiveMediaOnly: [Int64: Int] = [:]
    
    /// Зарегистрировать пост без текста
    func registerMediaOnlyPost(userId: Int64) -> Int {
        let current = userConsecutiveMediaOnly[userId] ?? 0
        let newCount = current + 1
        userConsecutiveMediaOnly[userId] = newCount
        return newCount
    }
    
    /// Зарегистрировать пост с текстом (сбрасывает счетчик)
    func registerPostWithText(userId: Int64) {
        userConsecutiveMediaOnly[userId] = 0
    }
    
    /// Получить текущий счетчик последовательных постов без текста
    func getConsecutiveCount(userId: Int64) -> Int {
        return userConsecutiveMediaOnly[userId] ?? 0
    }
}

/// Основной контроллер для обработки webhook'ов от Telegram
final class ContentFabrikaBotController: @unchecked Sendable {
    private static let deduplicator = UpdateIdDeduplicator()
    private static let rateLimiter = RateLimiter(limit: 2, interval: 60)
    private static let mediaOnlyTracker = MediaOnlyPostsTracker()
    
    func handleWebhook(_ req: Request) async throws -> Response {
        req.logger.info("🔔 handleWebhook called")
        
        guard let token = Environment.get("CONTENTFABRIKABOT_TOKEN"), !token.isEmpty else {
            req.logger.error("❌ CONTENTFABRIKABOT_TOKEN is missing")
            return Response(status: .internalServerError)
        }
        
        req.logger.info("✅ Token found, decoding update...")

        guard let update = try? req.content.decode(ContentFabrikaBotUpdate.self) else {
            req.logger.warning("⚠️ Failed to decode ContentFabrikaBotUpdate")
            if let bodyString = req.body.string {
                req.logger.info("Raw body: \(bodyString.prefix(500))")
            }
            return Response(status: .ok)
        }
        
        req.logger.info("✅ Update decoded successfully, update_id: \(update.update_id)")
        
        // Дедупликация: проверяем, не обрабатывали ли мы уже этот update_id
        let isDuplicate = await ContentFabrikaBotController.deduplicator.isDuplicate(update.update_id)
        
        if isDuplicate {
            req.logger.info("⚠️ Duplicate update_id \(update.update_id) - ignoring")
            return Response(status: .ok)
        }

        // Обработка callback query (кнопки) - ДОЛЖНО БЫТЬ ПЕРВЫМ
        if let callback = update.callback_query {
            req.logger.info("📱 Received callback_query: \(callback.data ?? "no data")")
            try await handleCallback(callback: callback, token: token, req: req)
            return Response(status: .ok)
        }

        guard let message = update.message else {
            req.logger.info("No message payload in update \(update.update_id)")
            return Response(status: .ok)
        }

        let text = message.text ?? ""
        let chatId = message.chat.id
        let userId = message.from?.id ?? chatId
        
        // Логируем информацию о сообщении для диагностики
        req.logger.info("💬 Message received: chat.type=\(message.chat.type ?? "nil"), has_forward_from_chat=\(message.forward_from_chat != nil), text_length=\(text.count), user_id=\(userId)")

        // Регистрируем пользователя в общей базе монетизации
        MonetizationService.registerUser(
            botName: "contentfabrikabot",
            chatId: chatId,
            logger: req.logger,
            env: req.application.environment
        )
        
        // Если пользователь нажал кнопку "Я подписался, проверить" —
        // повторно проверяем подписку и либо разблокируем, либо снова показываем требование.
        if text == "✅ Я подписался, проверить" {
            let (allowed, channels) = await MonetizationService.checkAccess(
                botName: "contentfabrikabot",
                userId: userId,
                logger: req.logger,
                env: req.application.environment,
                client: req.client
            )
            
            struct KeyboardButton: Content {
                let text: String
            }
            
            struct ReplyKeyboardMarkup: Content {
                let keyboard: [[KeyboardButton]]
                let resize_keyboard: Bool
                let one_time_keyboard: Bool
            }
            
            struct AccessPayloadWithKeyboard: Content {
                let chat_id: Int64
                let text: String
                let disable_web_page_preview: Bool
                let reply_markup: ReplyKeyboardMarkup?
            }
            
            struct ReplyKeyboardRemove: Content {
                let remove_keyboard: Bool
            }
            
            struct AccessPayloadWithRemoveKeyboard: Content {
                let chat_id: Int64
                let text: String
                let disable_web_page_preview: Bool
                let reply_markup: ReplyKeyboardRemove?
            }
            
            if allowed {
                // Удаляем клавиатуру "✅ Я подписался, проверить" после успешной проверки
                let removeKeyboard = ReplyKeyboardRemove(remove_keyboard: true)
                let removePayload = AccessPayloadWithRemoveKeyboard(
                    chat_id: chatId,
                    text: "Подписка подтверждена ✅",
                    disable_web_page_preview: false,
                    reply_markup: removeKeyboard
                )
                
                let sendMessageUrl = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
                _ = try await req.client.post(sendMessageUrl) { sendReq in
                    try sendReq.content.encode(removePayload, as: .json)
                }.get()
                // Проверяем, есть ли сохраненная тема
                if let (savedTopic, savedChannelId) = await TopicSessionManager.shared.getTopic(userId: userId) {
                    // Есть сохраненная тема - автоматически запускаем генерацию
                    await TopicSessionManager.shared.clearTopic(userId: userId)
                    
                    // Находим канал для генерации
                    let allChannels = try await ChannelService.findAllUserChannels(ownerUserId: userId, db: req.db)
                    let targetChannel: Channel
                    
                    if let savedChannelId = savedChannelId,
                       let foundChannel = allChannels.first(where: { (try? $0.requireID()) == savedChannelId }) {
                        targetChannel = foundChannel
                    } else if allChannels.count == 1 {
                        targetChannel = allChannels.first!
                    } else {
                        // Не можем определить канал - просим ввести тему заново
                        let successText = "Можешь отправить тему для поста, и я сгенерирую его в твоём стиле"
                        let keyboard = ReplyKeyboardMarkup(
                            keyboard: [[KeyboardButton(text: "📝 Сгенерировать пост")]],
                            resize_keyboard: true,
                            one_time_keyboard: false
                        )
                        let payload = AccessPayloadWithKeyboard(
                            chat_id: chatId,
                            text: successText,
                            disable_web_page_preview: false,
                            reply_markup: keyboard
                        )
                        
                        let sendMessageUrl = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
                        _ = try await req.client.post(sendMessageUrl) { sendReq in
                            try sendReq.content.encode(payload, as: .json)
                        }.get()
                        
                        return Response(status: .ok)
                    }
                    
                    let targetChannelId = try targetChannel.requireID()
                    guard let styleProfile = try await StyleService.getStyleProfile(channelId: targetChannelId, db: req.db) else {
                        // Стиль не изучен - просим ввести тему заново
                        let successText = "Можешь отправить тему для поста, и я сгенерирую его в твоём стиле."
                        let keyboard = ReplyKeyboardMarkup(
                            keyboard: [[KeyboardButton(text: "📝 Сгенерировать пост")]],
                            resize_keyboard: true,
                            one_time_keyboard: false
                        )
                        let payload = AccessPayloadWithKeyboard(
                            chat_id: chatId,
                            text: successText,
                            disable_web_page_preview: false,
                            reply_markup: keyboard
                        )
                        
                        let sendMessageUrl = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
                        _ = try await req.client.post(sendMessageUrl) { sendReq in
                            try sendReq.content.encode(payload, as: .json)
                        }.get()
                        
                        return Response(status: .ok)
                    }
                    
                    // Проверяем rate limit
                    let allowed = await ContentFabrikaBotController.rateLimiter.allow(userId: userId)
                    guard allowed else {
                        try await TelegramService.sendMessage(
                            token: token,
                            chatId: chatId,
                            text: "⚠️ Давай не торопиться — можно сгенерировать не больше двух постов в минуту. Попробуй ещё раз чуть позже 💛",
                            client: req.client
                        )
                        return Response(status: .ok)
                    }
                    
                    // Отправляем сообщение о начале генерации
                    _ = try? await TelegramService.sendMessage(
                        token: token,
                        chatId: chatId,
                        text: "Генерирую пост на тему: \"\(savedTopic)\"... ✨",
                        client: req.client
                    )
                    
                    // Запускаем генерацию в фоне
                    let client = req.client
                    let logger = req.logger
                    let app = req.application
                    let eventLoop = req.eventLoop
                    
                    Task { [token, userId, savedTopic] in
                        logger.info("🚀 Background task started for post generation (after subscription)")
                        do {
                            let backgroundReq = Request(application: app, method: .GET, url: URI(string: "/"), on: eventLoop)
                            
                            try await PostGenerationService.generatePostForUser(
                                topic: savedTopic,
                                styleProfile: styleProfile,
                                channel: targetChannel,
                                userId: userId,
                                token: token,
                                req: backgroundReq
                            )
                            logger.info("✅ Post generation completed (after subscription)")
                        } catch {
                            logger.error("❌ Error in background post generation (after subscription): \(error)")
                            let errorChatId = TelegramService.getChatIdFromUserId(userId: userId)
                            _ = try? await TelegramService.sendMessage(
                                token: token,
                                chatId: errorChatId,
                                text: "❌ Ошибка при генерации поста: \(error.localizedDescription)",
                                client: client
                            )
                        }
                    }
                    
                    return Response(status: .ok)
                } else {
                    // Нет сохраненной темы - показываем обычное сообщение
                    let successText = "Можешь отправить тему для поста, и я сгенерирую его в твоём стиле."
                    let keyboard = ReplyKeyboardMarkup(
                        keyboard: [[KeyboardButton(text: "📝 Сгенерировать пост")]],
                        resize_keyboard: true,
                        one_time_keyboard: false
                    )
                    let payload = AccessPayloadWithKeyboard(
                        chat_id: chatId,
                        text: successText,
                        disable_web_page_preview: false,
                        reply_markup: keyboard
                    )
                    
                    let sendMessageUrl = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
                    _ = try await req.client.post(sendMessageUrl) { sendReq in
                        try sendReq.content.encode(payload, as: .json)
                    }.get()
                    
                    return Response(status: .ok)
                }
            } else {
                let channelsText: String
                if channels.isEmpty {
                    channelsText = ""
                } else {
                    let listed = channels.map { "@\($0)" }.joined(separator: "\n")
                    channelsText = "\n\nПодпишись, пожалуйста, на спонсорские каналы:\n\(listed)"
                }
                
                let errorText = "Я всё ещё не вижу активную подписку.\n\nЧтобы воспользоваться ботом, нужна подписка на спонсорские каналы.\(channelsText)"
                let keyboard = ReplyKeyboardMarkup(
                    keyboard: [[KeyboardButton(text: "✅ Я подписался, проверить")]],
                    resize_keyboard: true,
                    one_time_keyboard: false
                )
                let payload = AccessPayloadWithKeyboard(
                    chat_id: chatId,
                    text: errorText,
                    disable_web_page_preview: false,
                    reply_markup: keyboard
                )
                
                let sendMessageUrl = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
                _ = try await req.client.post(sendMessageUrl) { sendReq in
                    try sendReq.content.encode(payload, as: .json)
                }.get()
                
                return Response(status: .ok)
            }
        }

        // Обработка команды /start
        if text == "/start" {
            try await WelcomeService.sendWelcome(userId: userId, chatId: chatId, token: token, req: req)
            return Response(status: .ok)
        }

        // Обработка команды /relearn
        if text == "/relearn" {
            try await StyleService.analyzeChannel(userId: userId, token: token, req: req, isRelearn: true)
            return Response(status: .ok)
        }
        
        // Обработка команды /reset - очистка данных профиля
        if text == "/reset" {
            try await handleResetCommand(userId: userId, chatId: chatId, token: token, req: req)
            return Response(status: .ok)
        }

        // Если сообщение переслано из канала - определяем канал автоматически
        if let forwardedChat = message.forward_from_chat, forwardedChat.type == "channel" {
            req.logger.info("📨 Forwarded from channel: id=\(forwardedChat.id), type=\(forwardedChat.type ?? "nil"), title=\(forwardedChat.title ?? "nil")")
            
            // Находим или создаем канал по telegramChatId
            let forwardedChatId = forwardedChat.id
            var channel = try await ChannelService.findChannelByTelegramId(
                telegramChatId: forwardedChatId,
                ownerUserId: userId,
                db: req.db
            )
            
            if channel == nil {
                channel = try await ChannelService.createOrUpdateChannel(
                    telegramChatId: forwardedChatId,
                    telegramChatTitle: forwardedChat.title,
                    ownerUserId: userId,
                    db: req.db
                )
            }
            
            // Сохраняем пересланный пост и уведомляем пользователя
            do {
                // Проверяем, есть ли текст в сообщении
                let hasText = !(message.text ?? message.caption ?? "").isEmpty
                
                // Регистрируем в tracker
                let consecutiveMediaOnly: Int
                if hasText {
                    await ContentFabrikaBotController.mediaOnlyTracker.registerPostWithText(userId: userId)
                    consecutiveMediaOnly = 0
                } else {
                    consecutiveMediaOnly = await ContentFabrikaBotController.mediaOnlyTracker.registerMediaOnlyPost(userId: userId)
                }
                
                let postsCount = try await PostService.saveForwardedPost(
                    message: message,
                    userId: userId,
                    token: token,
                    req: req
                )
                
                // Получаем статистику постов
                guard let channel = channel else {
                    throw Abort(.internalServerError, reason: "Channel not found")
                }
                let channelId = try channel.requireID()
                let stats = try await PostService.getPostsStatistics(channelId: channelId, db: req.db)
                
                let chatId = TelegramService.getChatIdFromUserId(userId: userId)
                
                // Формируем сообщение со статистикой
                var messageText = "✅ Получена публикация!\n\n📊 Статистика:\n• Всего сохранено: \(stats.total) постов\n• С текстом: \(stats.withText) постов (нужно минимум 3 для анализа)\n• Только медиа: \(stats.mediaOnly) постов"
                
                // Предупреждение при 2 постах подряд без текста
                if consecutiveMediaOnly >= 2 {
                    messageText += "\n\n⚠️ Обрати внимание!\n\nТы переслал \(consecutiveMediaOnly) пост(а) подряд без текста или подписи к медиа.\n\nДля изучения стиля канала нужны посты с текстом:\n• Минимум 3 поста с текстом или подписью к фото/видео\n• Посты только с картинками без подписи не помогут мне понять твой стиль\n\nПерешли посты, где есть текст или подпись к медиа 📝"
                }
                
                // Создаем клавиатуру с учетом статистики
                if stats.withText >= 3 {
                    let keyboard = KeyboardService.createAnalyzeChannelKeyboard(totalCount: stats.total, postsWithText: stats.withText)
                    try await TelegramService.sendMessageWithKeyboard(
                        token: token,
                        chatId: chatId,
                        text: messageText,
                        keyboard: keyboard,
                        client: req.client,
                        replyToMessageId: message.message_id
                    )
                } else {
                    let keyboard = KeyboardService.createAnalyzeChannelKeyboard(totalCount: stats.total, postsWithText: stats.withText)
                    if stats.total < 3 {
                        messageText += "\n\nДля изучения стиля нужно минимум 3 поста с текстом. Перешли еще \(3 - stats.withText) пост(а) с текстом."
                    } else {
                        messageText += "\n\n⚠️ У тебя \(stats.total) постов, но только \(stats.withText) из них содержат текст.\n\nДля изучения стиля нужно минимум 3 поста с текстом или подписью к медиа."
                    }
                    try await TelegramService.sendMessageWithKeyboard(
                        token: token,
                        chatId: chatId,
                        text: messageText,
                        keyboard: keyboard,
                        client: req.client,
                        replyToMessageId: message.message_id
                    )
                }
            } catch {
                req.logger.error("Error saving forwarded post: \(error)")
                let chatId = TelegramService.getChatIdFromUserId(userId: userId)
                try await TelegramService.sendMessage(
                    token: token,
                    chatId: chatId,
                    text: "❌ Ошибка при сохранении поста: \(error.localizedDescription)",
                    client: req.client
                )
            }
            
            return Response(status: .ok)
        }
        
        // Обычное сообщение от пользователя
        let channel = try await ChannelService.findUserChannel(ownerUserId: userId, db: req.db)
        
        // Если нет постов/каналов и это не команда - напоминаем переслать публикации
        if channel == nil && !text.hasPrefix("/") {
            req.logger.info("📩 User message without saved posts — sending reminder")
            try await WelcomeService.sendForwardReminder(userId: userId, chatId: chatId, token: token, req: req)
            return Response(status: .ok)
        }
        
        // Проверяем, есть ли у пользователя каналы
        let allChannels = try await ChannelService.findAllUserChannels(ownerUserId: userId, db: req.db)
        
        if allChannels.isEmpty {
            // У пользователя нет каналов - просим переслать посты
            try await TelegramService.sendMessage(
                token: token,
                chatId: chatId,
                text: "Сначала перешли мне от 3 до 10 постов из своего канала через Forward. Как только появится минимум 3 публикации, кнопка «Изучить канал» станет активной.",
                client: req.client
            )
        } else if allChannels.count == 1 {
            // Один канал - работаем с ним
            let channel = allChannels.first!
            let channelId = try channel.requireID()
            
            if let styleProfile = try await StyleService.getStyleProfile(channelId: channelId, db: req.db) {
                // Профиль готов - проверяем подписку перед генерацией
                let (subscriptionAllowed, channels) = await MonetizationService.checkAccess(
                    botName: "contentfabrikabot",
                    userId: userId,
                    logger: req.logger,
                    env: req.application.environment,
                    client: req.client
                )
                
                guard subscriptionAllowed else {
                    // Пользователь не подписан - сохраняем тему и отправляем сообщение с требованием подписки
                    await TopicSessionManager.shared.saveTopic(userId: userId, topic: text, channelId: channelId)
                    try await sendSubscriptionRequiredMessage(
                        chatId: chatId,
                        channels: channels,
                        token: token,
                        req: req
                    )
                    return Response(status: .ok)
                }
                
                // Генерируем пост в фоне (чтобы быстро ответить Telegram)
                let client = req.client
                let logger = req.logger
                let app = req.application
                let eventLoop = req.eventLoop
                
                let allowed = await ContentFabrikaBotController.rateLimiter.allow(userId: userId)
                guard allowed else {
                    try await TelegramService.sendMessage(
                        token: token,
                        chatId: chatId,
                        text: "⚠️ Давай не торопиться — можно сгенерировать не больше двух постов в минуту. Попробуй ещё раз чуть позже 💛",
                        client: req.client
                    )
                    return Response(status: .ok)
                }
                
                // Отправляем сообщение о начале генерации
                _ = try? await TelegramService.sendMessage(
                    token: token,
                    chatId: chatId,
                    text: "Генерирую пост в твоём стиле... ✨",
                    client: client
                )
                
                        // Запускаем генерацию в фоне
                        Task { [token, userId, text] in
                            logger.info("🚀 Background task started for post generation")
                            do {
                                // Создаём новый Request для фоновой обработки
                                // Request автоматически получает client из application
                                let backgroundReq = Request(application: app, method: .GET, url: URI(string: "/"), on: eventLoop)
                                
                                try await PostGenerationService.generatePostForUser(
                                    topic: text,
                                    styleProfile: styleProfile,
                                    channel: channel,
                                    userId: userId,
                                    token: token,
                                    req: backgroundReq
                                )
                                logger.info("✅ Post generation completed")
                            } catch {
                                logger.error("❌ Error in background post generation: \(error)")
                                logger.error("❌ Error details: \(error)")
                                if let abortError = error as? Abort {
                                    logger.error("❌ Abort error: status=\(abortError.status), reason=\(abortError.reason)")
                                }
                                let errorChatId = TelegramService.getChatIdFromUserId(userId: userId)
                                _ = try? await TelegramService.sendMessage(
                                    token: token,
                                    chatId: errorChatId,
                                    text: "❌ Ошибка при генерации поста: \(error.localizedDescription)",
                                    client: client
                                )
                            }
                        }
                
                // Возвращаем ответ сразу, обработка продолжается в фоне
                return Response(status: .ok)
            } else {
                // Профиль не готов - проверяем, есть ли посты в БД
                let stats = try await PostService.getPostsStatistics(channelId: channelId, db: req.db)
                
                if stats.total == 0 {
                    // Нет постов - просим переслать
                    let keyboard = KeyboardService.createAnalyzeChannelKeyboard(totalCount: stats.total, postsWithText: stats.withText)
                    try await TelegramService.sendMessageWithKeyboard(
                        token: token,
                        chatId: chatId,
                        text: "Сначала нужно изучить стиль канала.\n\n📝 Перешли мне от 3 до 10 постов из канала (Forward), затем нажми «Изучить канал».",
                        keyboard: keyboard,
                        client: req.client
                    )
                } else {
                    // Есть посты, но стиль не изучен - предлагаем изучить
                    let keyboard = KeyboardService.createAnalyzeChannelKeyboard(totalCount: stats.total, postsWithText: stats.withText)
                    var messageText = "Найдено \(stats.total) пост(ов) в базе данных"
                    if stats.withText < 3 {
                        messageText += ", но только \(stats.withText) из них содержат текст.\n\nДля изучения стиля нужно минимум 3 поста с текстом."
                    } else {
                        messageText += ". Нажми 'Изучить канал' для анализа стиля."
                    }
                    try await TelegramService.sendMessageWithKeyboard(
                        token: token,
                        chatId: chatId,
                        text: messageText,
                        keyboard: keyboard,
                        client: req.client
                    )
                }
            }
        } else {
            // Несколько каналов - проверяем подписку перед показом кнопок выбора канала
            let (subscriptionAllowed, channels) = await MonetizationService.checkAccess(
                botName: "contentfabrikabot",
                userId: userId,
                logger: req.logger,
                env: req.application.environment,
                client: req.client
            )
            
            guard subscriptionAllowed else {
                // Пользователь не подписан - сохраняем тему и отправляем сообщение с требованием подписки
                await TopicSessionManager.shared.saveTopic(userId: userId, topic: text)
                try await sendSubscriptionRequiredMessage(
                    chatId: chatId,
                    channels: channels,
                    token: token,
                    req: req
                )
                return Response(status: .ok)
            }
            
            // Просим выбрать канал для генерации поста
            var buttons: [[InlineKeyboardButton]] = []
            for channel in allChannels {
                let channelId = try channel.requireID()
                let channelTitle = channel.telegramChatTitle ?? "Канал \(channel.telegramChatId)"
                
                // Проверяем, есть ли у канала изученный стиль
                let hasStyleProfile = (try? await StyleProfile.query(on: req.db)
                    .filter(\.$channel.$id == channelId)
                    .filter(\.$isReady == true)
                    .first()) != nil
                
                if hasStyleProfile {
                    buttons.append([
                        InlineKeyboardButton(text: "📝 \(channelTitle)", callback_data: "generate_post:\(channelId.uuidString):\(text)")
                    ])
                }
            }
            
            if buttons.isEmpty {
                // Нет каналов с изученным стилем
                try await TelegramService.sendMessage(
                    token: token,
                    chatId: chatId,
                    text: "У тебя несколько каналов, но ни у одного не изучен стиль. Сначала изучи стиль канала через /start",
                    client: req.client
                )
            } else {
                let keyboard = InlineKeyboardMarkup(inline_keyboard: buttons)
                try await TelegramService.sendMessageWithKeyboard(
                    token: token,
                    chatId: chatId,
                    text: "У тебя несколько каналов. Выбери канал для генерации поста на тему: \"\(text)\"",
                    keyboard: keyboard,
                    client: req.client
                )
            }
        }

        return Response(status: .ok)
    }

    // MARK: - Вспомогательные функции для монетизации
    
    /// Отправляет сообщение с требованием подписки на спонсорские каналы
    private func sendSubscriptionRequiredMessage(
        chatId: Int64,
        channels: [String],
        token: String,
        req: Request
    ) async throws {
        struct KeyboardButton: Content {
            let text: String
        }
        
        struct ReplyKeyboardMarkup: Content {
            let keyboard: [[KeyboardButton]]
            let resize_keyboard: Bool
            let one_time_keyboard: Bool
        }
        
        struct AccessPayloadWithKeyboard: Content {
            let chat_id: Int64
            let text: String
            let disable_web_page_preview: Bool
            let reply_markup: ReplyKeyboardMarkup?
        }
        
        let channelsText: String
        if channels.isEmpty {
            channelsText = ""
        } else {
            let listed = channels.map { "@\($0)" }.joined(separator: "\n")
            channelsText = "\n\nПодпишись, пожалуйста, на спонсорские каналы:\n\(listed)"
        }
        
        let text = "Чтобы воспользоваться ботом, нужна подписка на спонсорские каналы.\nПосле подписки нажми кнопку «✅ Я подписался, проверить».\(channelsText)"
        let keyboard = ReplyKeyboardMarkup(
            keyboard: [[KeyboardButton(text: "✅ Я подписался, проверить")]],
            resize_keyboard: true,
            one_time_keyboard: false
        )
        let payload = AccessPayloadWithKeyboard(
            chat_id: chatId,
            text: text,
            disable_web_page_preview: false,
            reply_markup: keyboard
        )
        
        let sendMessageUrl = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
        _ = try await req.client.post(sendMessageUrl) { sendReq in
            try sendReq.content.encode(payload, as: .json)
        }.get()
    }

    // MARK: - Обработка пересланных сообщений
    
    private func handleChannelMessage(message: ContentFabrikaBotMessage, token: String, userId: Int64, req: Request) async throws {
        // Используем text или caption (подпись к фото/видео)
        let text = message.text ?? message.caption ?? ""
        req.logger.info("📨 handleChannelMessage: text=\(text.prefix(50)), caption=\(message.caption?.prefix(50) ?? "nil"), forward_from_chat=\(message.forward_from_chat != nil ? "yes" : "no")")
        
        // Если это пересланное сообщение из канала, сохраняем его
        if let forwardedChat = message.forward_from_chat, forwardedChat.type == "channel" {
            req.logger.info("✅ Forwarded message from channel: \(forwardedChat.id) (\(forwardedChat.title ?? "no title"))")
            
            // Проверяем, есть ли текст в сообщении
            let hasText = !text.isEmpty
            
            // Регистрируем в tracker
            let consecutiveMediaOnly: Int
            if hasText {
                await ContentFabrikaBotController.mediaOnlyTracker.registerPostWithText(userId: userId)
                consecutiveMediaOnly = 0
            } else {
                consecutiveMediaOnly = await ContentFabrikaBotController.mediaOnlyTracker.registerMediaOnlyPost(userId: userId)
            }
            
            do {
                let postsCount = try await PostService.saveForwardedPost(
                    message: message,
                    userId: userId,
                    token: token,
                    req: req
                )
                
                // Получаем статистику постов
                var channel = try await Channel.query(on: req.db)
                    .filter(\.$telegramChatId == forwardedChat.id)
                    .first()
                
                guard let channel = channel else {
                    throw Abort(.internalServerError, reason: "Channel not found")
                }
                
                let channelId = try channel.requireID()
                let stats = try await PostService.getPostsStatistics(channelId: channelId, db: req.db)
                
                // Уведомляем пользователя о сохранении
                let chatId = TelegramService.getChatIdFromUserId(userId: userId)
                
                // Формируем сообщение со статистикой
                var messageText = "✅ Получена публикация!\n\n📊 Статистика:\n• Всего сохранено: \(stats.total) постов\n• С текстом: \(stats.withText) постов (нужно минимум 3 для анализа)\n• Только медиа: \(stats.mediaOnly) постов"
                
                // Предупреждение при 2 постах подряд без текста
                if consecutiveMediaOnly >= 2 {
                    messageText += "\n\n⚠️ Обрати внимание!\n\nТы переслал \(consecutiveMediaOnly) пост(а) подряд без текста или подписи к медиа.\n\nДля изучения стиля канала нужны посты с текстом:\n• Минимум 3 поста с текстом или подписью к фото/видео\n• Посты только с картинками без подписи не помогут мне понять твой стиль\n\nПерешли посты, где есть текст или подпись к медиа 📝"
                }
                
                // Создаем клавиатуру с учетом статистики
                if stats.withText >= 3 {
                    let keyboard = KeyboardService.createAnalyzeChannelKeyboard(totalCount: stats.total, postsWithText: stats.withText)
                    try await TelegramService.sendMessageWithKeyboard(
                        token: token,
                        chatId: chatId,
                        text: messageText,
                        keyboard: keyboard,
                        client: req.client,
                        replyToMessageId: message.message_id
                    )
                } else {
                    let keyboard = KeyboardService.createAnalyzeChannelKeyboard(totalCount: stats.total, postsWithText: stats.withText)
                    if stats.total < 3 {
                        messageText += "\n\nДля изучения стиля нужно минимум 3 поста с текстом. Перешли еще \(3 - stats.withText) пост(а) с текстом."
                    } else {
                        messageText += "\n\n⚠️ У тебя \(stats.total) постов, но только \(stats.withText) из них содержат текст.\n\nДля изучения стиля нужно минимум 3 поста с текстом или подписью к медиа."
                    }
                    try await TelegramService.sendMessageWithKeyboard(
                        token: token,
                        chatId: chatId,
                        text: messageText,
                        keyboard: keyboard,
                        client: req.client,
                        replyToMessageId: message.message_id
                    )
                }
            } catch {
                req.logger.error("Error saving forwarded post: \(error)")
                let chatId = TelegramService.getChatIdFromUserId(userId: userId)
                try await TelegramService.sendMessage(
                    token: token,
                    chatId: chatId,
                    text: "❌ Ошибка при сохранении поста: \(error.localizedDescription)",
                    client: req.client
                )
            }
        } else {
            // Обычное текстовое сообщение (не пересланное) - возможно пользователь хочет создать пост
            // Но если стиль не изучен, напоминаем об этом
            let chatId = TelegramService.getChatIdFromUserId(userId: userId)
            
            if let channel = try await ChannelService.findUserChannel(ownerUserId: userId, db: req.db) {
                let channelId = try channel.requireID()
                let hasStyleProfile = try await StyleService.getStyleProfile(channelId: channelId, db: req.db) != nil
                
                if !hasStyleProfile {
                    // Стиль не изучен - напоминаем
                    let keyboard = InlineKeyboardMarkup(inline_keyboard: [[
                        InlineKeyboardButton(text: "📚 Изучить канал", callback_data: "analyze_channel")
                    ]])
                    try await TelegramService.sendMessageWithKeyboard(
                        token: token,
                        chatId: chatId,
                        text: "Сначала нужно изучить стиль канала. Перешли мне от 3 до 10 постов из канала (Forward), затем нажми «Изучить канал».",
                        keyboard: keyboard,
                        client: req.client
                    )
                }
            }
        }
    }

    // MARK: - Обработка callback query
    
    private func handleCallback(callback: ContentFabrikaBotCallbackQuery, token: String, req: Request) async throws {
        guard let data = callback.data else { return }
        
        let userId = callback.from.id
        let chatId = TelegramService.getChatIdFromUserId(userId: userId)
        
        // Получаем message_id из callback для reply (если есть)
        let replyToMessageId = callback.message?.message_id
        
        // Обработка выбора канала для анализа
        if data.hasPrefix("analyze_channel:") {
            let channelIdString = String(data.dropFirst("analyze_channel:".count))
            try await TelegramService.answerCallbackQuery(
                token: token,
                callbackId: callback.id,
                text: "Начинаю анализ канала...",
                req: req
            )
            try await StyleService.analyzeChannel(userId: userId, token: token, req: req, isRelearn: false, channelId: channelIdString, replyToMessageId: replyToMessageId)
        } else if data == "analyze_channel" {
            // Показываем список каналов, если их несколько
            let channels = try await ChannelService.findAllUserChannels(ownerUserId: userId, db: req.db)
            
            if channels.isEmpty {
                try await TelegramService.answerCallbackQuery(
                    token: token,
                    callbackId: callback.id,
                    text: "Не найден канал с постами. Перешли мне публикации через Forward.",
                    req: req
                )
                // Отправляем сообщение как reply к предыдущему
                _ = try await TelegramService.sendMessage(
                    token: token,
                    chatId: chatId,
                        text: "❌ Я ещё не знаю твой канал.\n\nПерешли мне от 3 до 10 постов (Forward), и кнопка «Изучить канал» станет доступной.",
                    client: req.client,
                    replyToMessageId: replyToMessageId
                )
                return
            } else if channels.count == 1 {
                // Если канал один - сразу анализируем
                try await TelegramService.answerCallbackQuery(
                    token: token,
                    callbackId: callback.id,
                    text: "Начинаю анализ канала...",
                    req: req
                )
                let channelId = try channels.first!.requireID()
                try await StyleService.analyzeChannel(userId: userId, token: token, req: req, isRelearn: false, channelId: channelId.uuidString, replyToMessageId: replyToMessageId)
            } else {
                // Если каналов несколько - показываем список для выбора
                try await TelegramService.answerCallbackQuery(
                    token: token,
                    callbackId: callback.id,
                    text: "Выбери канал для анализа",
                    req: req
                )
                
                var buttons: [[InlineKeyboardButton]] = []
                for channel in channels {
                    let channelId = try channel.requireID()
                    let channelTitle = channel.telegramChatTitle ?? "Канал \(channel.telegramChatId)"
                    buttons.append([
                        InlineKeyboardButton(text: "📺 \(channelTitle)", callback_data: "analyze_channel:\(channelId.uuidString)")
                    ])
                }
                
                // Добавляем кнопку удаления данных в конец
                buttons.append([
                    InlineKeyboardButton(text: "🗑️ Удалить все данные", callback_data: "reset_all_data")
                ])
                
                let keyboard = InlineKeyboardMarkup(inline_keyboard: buttons)
                try await TelegramService.sendMessageWithKeyboard(
                    token: token,
                    chatId: chatId,
                    text: "У тебя несколько каналов. Выбери канал для изучения стиля:",
                    keyboard: keyboard,
                    client: req.client
                )
            }
        } else if data.hasPrefix("relearn_style:") {
            let channelIdString = String(data.dropFirst("relearn_style:".count))
            try await TelegramService.answerCallbackQuery(
                token: token,
                callbackId: callback.id,
                text: "Переизучаю стиль канала...",
                req: req
            )
            try await StyleService.analyzeChannel(userId: userId, token: token, req: req, isRelearn: true, channelId: channelIdString, replyToMessageId: replyToMessageId)
        } else if data == "relearn_style" {
            // Показываем список каналов для переобучения
            let channels = try await ChannelService.findAllUserChannels(ownerUserId: userId, db: req.db)
            
            if channels.isEmpty {
                try await TelegramService.answerCallbackQuery(
                    token: token,
                    callbackId: callback.id,
                    text: "Не найден канал для переобучения. Перешли мне посты заново.",
                    req: req
                )
                // Отправляем сообщение как reply к предыдущему
                _ = try await TelegramService.sendMessage(
                    token: token,
                    chatId: chatId,
                    text: "❌ Пока нет канала для переобучения. Собери минимум 3 пересланных поста и изучи стиль, а потом я смогу его обновить.",
                    client: req.client,
                    replyToMessageId: replyToMessageId
                )
                return
            } else if channels.count == 1 {
                try await TelegramService.answerCallbackQuery(
                    token: token,
                    callbackId: callback.id,
                    text: "Переизучаю стиль канала...",
                    req: req
                )
                let channelId = try channels.first!.requireID()
                try await StyleService.analyzeChannel(userId: userId, token: token, req: req, isRelearn: true, channelId: channelId.uuidString, replyToMessageId: replyToMessageId)
            } else {
                try await TelegramService.answerCallbackQuery(
                    token: token,
                    callbackId: callback.id,
                    text: "Выбери канал для переобучения",
                    req: req
                )
                
                        var buttons: [[InlineKeyboardButton]] = []
                        for channel in channels {
                            let channelId = try channel.requireID()
                            let channelTitle = channel.telegramChatTitle ?? "Канал \(channel.telegramChatId)"
                            buttons.append([
                                InlineKeyboardButton(text: "🔄 \(channelTitle)", callback_data: "relearn_style:\(channelId.uuidString)")
                            ])
                        }
                        
                        // Добавляем кнопку удаления данных в конец
                        buttons.append([
                            InlineKeyboardButton(text: "🗑️ Удалить все данные", callback_data: "reset_all_data")
                        ])
                        
                        let keyboard = InlineKeyboardMarkup(inline_keyboard: buttons)
                try await TelegramService.sendMessageWithKeyboard(
                    token: token,
                    chatId: chatId,
                    text: "У тебя несколько каналов. Выбери канал для переобучения стиля:",
                    keyboard: keyboard,
                    client: req.client
                )
            }
        } else if data.hasPrefix("generate_post:") {
            // Генерация поста для конкретного канала
            let parts = data.split(separator: ":")
            if parts.count >= 3 {
                let channelIdString = String(parts[1])
                let topic = parts.dropFirst(2).joined(separator: ":") // Восстанавливаем тему (может содержать :)
                
                if let channelUUID = UUID(uuidString: channelIdString),
                   let channel = try await Channel.query(on: req.db)
                    .filter(\.$id == channelUUID)
                    .filter(\.$ownerUserId == userId)
                    .first(),
                   let styleProfile = try await StyleService.getStyleProfile(channelId: channelUUID, db: req.db) {
                    
                    // Проверяем подписку перед генерацией
                    let (subscriptionAllowed, channels) = await MonetizationService.checkAccess(
                        botName: "contentfabrikabot",
                        userId: userId,
                        logger: req.logger,
                        env: req.application.environment,
                        client: req.client
                    )
                    
                    guard subscriptionAllowed else {
                        // Пользователь не подписан - сохраняем тему и отправляем сообщение с требованием подписки
                        await TopicSessionManager.shared.saveTopic(userId: userId, topic: topic, channelId: channelUUID)
                        _ = try? await TelegramService.answerCallbackQuery(
                            token: token,
                            callbackId: callback.id,
                            text: "Требуется подписка на спонсорские каналы",
                            req: req
                        )
                        try await sendSubscriptionRequiredMessage(
                            chatId: chatId,
                            channels: channels,
                            token: token,
                            req: req
                        )
                        return
                    }
                            
                            let allowed = await ContentFabrikaBotController.rateLimiter.allow(userId: userId)
                            guard allowed else {
                                _ = try? await TelegramService.answerCallbackQuery(
                                    token: token,
                                    callbackId: callback.id,
                                    text: "Подожди немного перед следующей генерацией",
                                    req: req
                                )
                                _ = try? await TelegramService.sendMessage(
                                    token: token,
                                    chatId: chatId,
                                    text: "⚠️ Можно генерировать не больше двух постов в минуту. Подожди чуть-чуть и попробуй снова 💛",
                                    client: req.client,
                                    replyToMessageId: replyToMessageId
                                )
                                return
                            }
                    
                    _ = try await TelegramService.answerCallbackQuery(
                        token: token,
                        callbackId: callback.id,
                        text: nil,  // Убираем дублирующее сообщение - оно будет отправлено в PostGenerationService
                        req: req
                    )
                    
                    // Генерируем пост в фоне (чтобы быстро ответить Telegram)
                    let client = req.client
                    let logger = req.logger
                    let app = req.application
                    let eventLoop = req.eventLoop
                    
                    // Отправляем сообщение о начале генерации
                    _ = try? await TelegramService.sendMessage(
                        token: token,
                        chatId: chatId,
                        text: "Генерирую пост в твоём стиле... ✨",
                        client: client
                    )
                    
                    // Запускаем генерацию в фоне
                    Task { [token, userId, topic] in
                        logger.info("🚀 Background task started for post generation (callback)")
                        do {
                            // Создаём новый Request для фоновой обработки
                            // Request автоматически получает client из application
                            let backgroundReq = Request(application: app, method: .GET, url: URI(string: "/"), on: eventLoop)
                            
                                    try await PostGenerationService.generatePostForUser(
                                topic: topic,
                                styleProfile: styleProfile,
                                channel: channel,
                                userId: userId,
                                token: token,
                                req: backgroundReq
                            )
                            logger.info("✅ Post generation completed (callback)")
                        } catch {
                            logger.error("❌ Error in background post generation (callback): \(error)")
                            logger.error("❌ Error details: \(error)")
                                if let abortError = error as? Abort {
                                    logger.error("❌ Abort error: status=\(abortError.status), reason=\(abortError.reason)")
                            }
                            let errorChatId = TelegramService.getChatIdFromUserId(userId: userId)
                            _ = try? await TelegramService.sendMessage(
                                token: token,
                                chatId: errorChatId,
                                text: "❌ Ошибка при генерации поста: \(error.localizedDescription)",
                                client: client
                            )
                        }
                    }
                } else {
                    try await TelegramService.answerCallbackQuery(
                        token: token,
                        callbackId: callback.id,
                        text: "Ошибка: канал не найден или стиль не изучен",
                        req: req
                    )
                }
            }
        } else if data == "create_new_post" {
            // Кнопка "Сгенерировать пост" - отправляем инструкцию
            try await TelegramService.answerCallbackQuery(
                token: token,
                callbackId: callback.id,
                text: "Отправь мне тему для генерации поста",
                req: req
            )
            
            // Отправляем сообщение с инструкцией
            try await TelegramService.sendMessage(
                token: token,
                chatId: chatId,
                text: "📝 Отправь мне тему для поста, и я автоматически сгенерирую его в твоём стиле",
                client: req.client
            )
        } else if data == "reset_all_data" {
            // Кнопка "Удалить все данные" - подтверждение
            try await TelegramService.answerCallbackQuery(
                token: token,
                callbackId: callback.id,
                text: "Удаляю все данные...",
                req: req
            )
            try await handleResetCommand(userId: userId, chatId: chatId, token: token, req: req)
        } else {
            try await TelegramService.answerCallbackQuery(
                token: token,
                callbackId: callback.id,
                text: nil,
                req: req
            )
        }
    }
    
    // MARK: - Обработка команды /reset
    
    private func handleResetCommand(userId: Int64, chatId: Int64, token: String, req: Request) async throws {
        // Находим все каналы пользователя
        let allChannels = try await ChannelService.findAllUserChannels(ownerUserId: userId, db: req.db)
        
        if allChannels.isEmpty {
            try await TelegramService.sendMessage(
                token: token,
                chatId: chatId,
                text: "✅ У тебя нет сохраненных данных. Можешь начать работу с ботом!",
                client: req.client
            )
            return
        }
        
        // Удаляем все данные пользователя
        var deletedChannelsCount = 0
        var deletedPostsCount = 0
        var deletedProfilesCount = 0
        
        for channel in allChannels {
            let channelId = try channel.requireID()
            
            // Удаляем профили стиля для этого канала
            let profiles = try await StyleProfile.query(on: req.db)
                .filter(\.$channel.$id == channelId)
                .all()
            deletedProfilesCount += profiles.count
            try await StyleProfile.query(on: req.db)
                .filter(\.$channel.$id == channelId)
                .delete()
            
            // Удаляем все посты канала
            let posts = try await ChannelPost.query(on: req.db)
                .filter(\.$channel.$id == channelId)
                .all()
            deletedPostsCount += posts.count
            try await ChannelPost.query(on: req.db)
                .filter(\.$channel.$id == channelId)
                .delete()
            
            // Деактивируем канал
            channel.isActive = false
            try await channel.update(on: req.db)
            deletedChannelsCount += 1
        }
        
        req.logger.info("🔄 Reset completed for user \(userId): \(deletedChannelsCount) channels, \(deletedPostsCount) posts, \(deletedProfilesCount) profiles")
        
        let keyboard = KeyboardService.createSimpleAnalyzeKeyboard()
        
        // Отправляем сообщение об удалении данных
        _ = try await TelegramService.sendMessageWithKeyboard(
            token: token,
            chatId: chatId,
            text: "✅ Все данные удалены!\n\n🗑️ Удалено:\n• \(deletedChannelsCount) канал(ов)\n• \(deletedPostsCount) пост(ов)\n• \(deletedProfilesCount) профиль(ей) стиля\n\nНачнём заново:\n1. Перешли мне от 3 до 10 постов (Forward) из нужного канала\n2. Дождись, когда появится кнопка «Изучить канал»\n3. Запусти анализ и отправляй темы для новых постов",
            keyboard: keyboard,
            client: req.client
        )
    }
}
