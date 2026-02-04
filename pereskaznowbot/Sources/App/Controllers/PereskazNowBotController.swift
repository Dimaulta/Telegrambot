import Vapor
import Foundation

final class PereskazNowBotController: @unchecked Sendable {
    // Rate limiter: 1 запрос в 2 минуты на пользователя
    private static let rateLimiter = RateLimiter(maxRequests: 1, timeWindow: 120)
    
    // Daily limiter: 20 видео в день на пользователя
    private static let dailyLimiter = DailyLimiter()
    
    // Дедупликация: храним последние обработанные update_id (чтобы не обрабатывать дубликаты от Telegram)
    private static let updateDeduplicator = UpdateDeduplicator()
    private static let maxStoredUpdates = 1000 // Храним последние 1000 update_id
    
    // Трекер обрабатываемых ссылок (защита от дубликатов)
    private static let processingLinksTracker = ProcessingLinksTracker()
    
    // Максимальная длительность видео (30 минут)
    private static let maxVideoDurationMinutes = 30
    
    func handleWebhook(_ req: Request) async throws -> Response {
        req.logger.info("═══════════════════════════════════════════════")
        req.logger.info("🔔 PereskazNowBot webhook hit!")
        req.logger.info("Method: \(req.method), Path: \(req.url.path)")
        
        let token = Environment.get("PERESKAZNOWBOT_TOKEN")
        guard let token = token, token.isEmpty == false else {
            req.logger.error("PERESKAZNOWBOT_TOKEN is missing")
            return Response(status: .internalServerError)
        }

        let rawBody = req.body.string ?? ""
        req.logger.info("📦 Raw body length: \(rawBody.count) characters")
        if rawBody.count > 0 && rawBody.count < 500 {
            req.logger.debug("Raw body: \(rawBody)")
        }

        req.logger.info("🔍 Decoding PereskazNowBotUpdate...")
        let update = try? req.content.decode(PereskazNowBotUpdate.self)
        if update == nil { 
            req.logger.error("❌ Failed to decode PereskazNowBotUpdate - check raw body above")
            return Response(status: .ok)
        }
        req.logger.info("✅ PereskazNowBotUpdate decoded successfully")

        // Проверяем дедупликацию: если этот update_id уже обработан, игнорируем
        guard let updateId = update?.update_id else {
            req.logger.warning("⚠️ No update_id in update")
            return Response(status: .ok)
        }
        
        req.logger.info("🔍 Checking duplicate for update_id=\(updateId)")
        let isDuplicate = await Self.updateDeduplicator.checkAndAdd(updateId: updateId)
        if isDuplicate {
            req.logger.info("⚠️ Duplicate update_id \(updateId) - already processed, ignoring")
            return Response(status: .ok)
        }
        req.logger.info("✅ Update_id \(updateId) is new, processing...")

        guard let message = update?.message else {
            req.logger.warning("⚠️ No message in update (update_id: \(updateId))")
            return Response(status: .ok)
        }
        
        let text = message.text ?? ""
        let chatId = message.chat.id
        let userId = chatId
        
        req.logger.info("📨 Incoming message - chatId=\(chatId), text length=\(text.count)")
        if !text.isEmpty {
            req.logger.info("📝 Message text: \(text.prefix(200))")
        }

        // Регистрируем пользователя в общей базе монетизации
        MonetizationService.registerUser(
            botName: "pereskaznowbot",
            chatId: chatId,
            logger: req.logger,
            env: req.application.environment
        )

        // Если пользователь нажал кнопку "Я подписался, проверить" —
        // повторно проверяем подписку и либо разблокируем, либо снова показываем требование.
        if text == "✅ Я подписался, проверить" {
            let (allowed, channels) = await MonetizationService.checkAccess(
                botName: "pereskaznowbot",
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
            
            struct ReplyKeyboardRemove: Content {
                let remove_keyboard: Bool
            }
            
            struct AccessPayloadWithKeyboard: Content {
                let chat_id: Int64
                let text: String
                let disable_web_page_preview: Bool
                let reply_markup: ReplyKeyboardMarkup?
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
                
                // Проверяем, есть ли сохраненная ссылка для автоматической обработки
                if let savedUrl = await VideoUrlSessionManager.shared.getUrl(userId: userId) {
                    // Есть сохраненная ссылка - автоматически обрабатываем её
                    req.logger.info("✅ Subscription confirmed, processing saved URL: \(savedUrl)")
                    
                    // Очищаем сохраненную ссылку перед обработкой
                    await VideoUrlSessionManager.shared.clearUrl(userId: userId)
                    
                    // Продолжаем обработку сохраненной ссылки
                    // Выполняем все проверки и обработку для сохраненной ссылки
                    return try await processVideoUrl(
                        youtubeUrl: savedUrl,
                        chatId: chatId,
                        userId: userId,
                        token: token,
                        req: req
                    )
                } else {
                    // Нет сохраненной ссылки - просто сообщаем об успешной подписке
                    let successText = "Можешь отправить ссылку на YouTube видео, и я верну тебе краткое содержание."
                    let keyboard = ReplyKeyboardMarkup(
                        keyboard: [[KeyboardButton(text: "🎬 Отправить ссылку")]],
                        resize_keyboard: true,
                        one_time_keyboard: false
                    )
                    let payload = AccessPayloadWithKeyboard(
                        chat_id: chatId,
                        text: successText,
                        disable_web_page_preview: false,
                        reply_markup: keyboard
                    )
                    
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

        // Обработка команды /start (с параметрами или без)
        if text == "/start" || text.hasPrefix("/start ") {
            req.logger.info("✅ Command /start received for chatId=\(chatId), update_id=\(updateId)")
            
            // Дополнительная проверка по времени (защита от дубликатов с разными update_id)
            let canProcessStart = await StartCommandTracker.shared.canProcess(chatId: chatId)
            if !canProcessStart {
                req.logger.info("⚠️ /start command for chatId=\(chatId) processed too recently (within 5 seconds), ignoring duplicate")
                return Response(status: .ok)
            }
            
            do {
                let welcomeText = "Привет! 👋\n\nЯ бот для получения расшифровки и саммари YouTube видео! 🎬\n\nПросто отправь мне ссылку на YouTube видео, и я верну тебе краткое содержание.\n\n⚙️ Ограничения:\n• Максимальная длительность видео: \(Self.maxVideoDurationMinutes) минут\n• Не более 1 ссылки в 2 минуты\n• Не более 20 видео в день"
                req.logger.info("📤 Attempting to send start message to chatId=\(chatId)")
                try await sendTelegramMessage(
                    token: token,
                    chatId: message.chat.id,
                    text: welcomeText,
                    client: req.client
                )
                req.logger.info("✅ Start message sent successfully to chatId=\(chatId)")
            } catch {
                req.logger.error("❌ Failed to send start message to chatId=\(chatId): \(error)")
                req.logger.error("❌ Error details: \(String(describing: error))")
            }
            return Response(status: .ok)
        }

        // Проверяем наличие YouTube URL в сообщении
        guard let youtubeUrl = extractYouTubeURL(from: text) else {
            req.logger.info("ℹ️ No YouTube URL found in message (text: \(text.prefix(100)))")
            // Отправляем сообщение с инструкцией, если это не ссылка и не команда
            if !text.isEmpty && !text.hasPrefix("/") {
                _ = try? await sendTelegramMessage(
                    token: token,
                    chatId: message.chat.id,
                    text: "Привет! 👋 Отправь мне ссылку на YouTube видео, и я верну тебе краткое содержание! 🎬",
                    client: req.client
                )
            }
            return Response(status: .ok)
        }
        
        req.logger.info("✅ Detected YouTube URL: \(youtubeUrl)")

        // Проверка rate limit (1 запрос в 2 минуты)
        let canProceed = await Self.rateLimiter.checkLimit(for: chatId)
        
        if !canProceed {
            req.logger.warning("⚠️ Rate limit exceeded for user \(chatId)")
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: "⏱️ Ты уже отправил ссылку в последние 2 минуты. Подожди немного и попробуй снова 💕",
                client: req.client
            )
            return Response(status: .ok)
        }
        
        // Проверка дневного лимита (20 видео в день)
        let canProceedDaily = await Self.dailyLimiter.checkLimit(for: chatId)
        
        if !canProceedDaily {
            req.logger.warning("⚠️ Daily limit exceeded for user \(chatId)")
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: "📊 Ты уже использовал дневной лимит (20 видео в день). Попробуй завтра! 💕",
                client: req.client
            )
            return Response(status: .ok)
        }
        
        // Показываем оставшиеся запросы (опционально, для информации)
        let remaining = await Self.dailyLimiter.getRemainingRequests(for: chatId)
        if remaining <= 5 {
            req.logger.info("ℹ️ User \(chatId) has \(remaining) requests remaining today")
        }
        
        // Проверка длительности видео (максимум 30 минут)
        do {
            let durationMinutes = try await getVideoDuration(videoUrl: youtubeUrl, logger: req.logger)
            req.logger.info("📹 Video duration: \(durationMinutes) minutes")
            
            if durationMinutes > Self.maxVideoDurationMinutes {
                req.logger.warning("⚠️ Video too long: \(durationMinutes) minutes (max: \(Self.maxVideoDurationMinutes))")
                _ = try? await sendTelegramMessage(
                    token: token,
                    chatId: chatId,
                    text: "⏱️ Видео слишком длинное (\(durationMinutes) минут). Максимальная длительность: \(Self.maxVideoDurationMinutes) минут.",
                    client: req.client
                )
                return Response(status: .ok)
            }
        } catch {
            req.logger.warning("⚠️ Failed to get video duration: \(error), proceeding anyway")
            // Продолжаем обработку, если не удалось получить длительность
        }

        // Сохраняем ссылку перед проверкой подписки (для автоматической обработки после подтверждения)
        await VideoUrlSessionManager.shared.saveUrl(userId: userId, url: youtubeUrl)

        // Проверяем подписку перед обработкой ссылки
        let (subscriptionAllowed, channels) = await MonetizationService.checkAccess(
            botName: "pereskaznowbot",
            userId: userId,
            logger: req.logger,
            env: req.application.environment,
            client: req.client
        )
        
        guard subscriptionAllowed else {
            // Пользователь не подписан - отправляем сообщение с требованием подписки
            try await sendSubscriptionRequiredMessage(
                chatId: chatId,
                channels: channels,
                token: token,
                req: req
            )
            return Response(status: .ok)
        }

        // Обрабатываем ссылку через вынесенную функцию
        return try await processVideoUrl(
            youtubeUrl: youtubeUrl,
            chatId: chatId,
            userId: userId,
            token: token,
            req: req
        )
    }
    
    // MARK: - Обработка видео
    
    /// Обрабатывает YouTube ссылку (вынесено в отдельную функцию для переиспользования)
    private func processVideoUrl(
        youtubeUrl: String,
        chatId: Int64,
        userId: Int64,
        token: String,
        req: Request
    ) async throws -> Response {
        // Извлекаем videoId для проверки дубликатов
        guard let videoId = extractVideoIdFromURL(youtubeUrl) else {
            req.logger.error("❌ Could not extract video ID from URL: \(youtubeUrl)")
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: "😔 Не удалось извлечь ID видео из ссылки. Проверь, что ссылка корректна.",
                client: req.client
            )
            return Response(status: .ok)
        }
        
        // Проверка на дубликаты: обрабатывается ли уже эта ссылка
        let isAlreadyProcessing = await Self.processingLinksTracker.isProcessing(link: videoId)
        if isAlreadyProcessing {
            req.logger.warning("⚠️ Link already processing: \(videoId)")
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: "⏳ Эта ссылка уже обрабатывается, подожди немного...",
                client: req.client
            )
            return Response(status: .ok)
        }
        
        // Добавляем ссылку в трекер обрабатываемых
        await Self.processingLinksTracker.addProcessing(link: videoId)
        
        defer {
            // Удаляем ссылку из трекера после завершения обработки
            Task {
                await Self.processingLinksTracker.removeProcessing(link: videoId)
            }
        }
        
        // Отправляем typing indicator
        _ = try? await sendTypingIndicator(token: token, chatId: chatId, client: req.client)
        
        // Отправляем сообщение о начале обработки
        _ = try? await sendTelegramMessage(
            token: token,
            chatId: chatId,
            text: "Обрабатываю ссылку... 🎬\nЭто может занять 2-3 минуты...",
            client: req.client
        )

        // Выполняем обработку
        let client = req.client
        let logger = req.logger

        do {
            logger.info("🚀 Processing YouTube URL: \(youtubeUrl)")
            logger.info("🔍 URL length: \(youtubeUrl.count), isEmpty: \(youtubeUrl.isEmpty)")
            
            let processingStartTime = Date()
            
            // Шаг 1: Получаем транскрипцию
            logger.info("📡 Step 1: Getting transcript...")
            let transcript = try await PereskazService.shared.getTranscript(
                videoUrl: youtubeUrl,
                client: client,
                logger: logger
            )
            logger.info("✅ Transcript received, length: \(transcript.count) characters")
            
            // Отправляем промежуточное сообщение после получения транскрипции
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: "✅ Транскрипция получена!\n\n🤖 Создаю краткое содержание...",
                client: client
            )
            
            // Шаг 2: Создаем саммари через GPT
            logger.info("📡 Step 2: Generating summary with GPT...")
            let summary = try await PereskazService.shared.getSummaryWithGPT(
                transcript: transcript,
                client: client,
                logger: logger
            )
            
            let processingElapsed = Date().timeIntervalSince(processingStartTime)
            logger.info("✅ Summary received in \(Int(processingElapsed)) seconds, length: \(summary.count) characters")
            
            // Отправляем саммари пользователю (с разбиением на части, если нужно)
            logger.info("📤 Sending summary to user...")
            try await sendSummaryMessage(
                token: token,
                chatId: chatId,
                summary: summary,
                client: client,
                logger: logger
            )
            
            logger.info("✅ Summary sent successfully")
            
            // Очищаем сохраненную ссылку после успешной обработки
            await VideoUrlSessionManager.shared.clearUrl(userId: userId)
        } catch {
            logger.error("❌ Error processing YouTube video: \(error)")
            
            // Отправляем пользователю понятное сообщение об ошибке
            var errorMessage: String
            if let abort = error as? Abort {
                if abort.status == .badRequest {
                    // abort.reason уже String, не optional
                    errorMessage = abort.reason.isEmpty ? "Произошла ошибка при обработке видео" : abort.reason
                } else {
                    errorMessage = "Произошла ошибка при обработке видео. Попробуй позже."
                }
            } else {
                errorMessage = "Произошла ошибка при обработке видео. Попробуй позже."
            }
            
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: "😔 \(errorMessage)",
                client: client
            )
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
    
    // MARK: - Обработка YouTube ссылок
    
    /// Извлекает video ID из YouTube URL (включая Shorts)
    private func extractVideoIdFromURL(_ url: String) -> String? {
        // Паттерны для извлечения video ID
        let patterns = [
            #"youtube\.com/watch\?v=([\w-]+)"#,
            #"youtu\.be/([\w-]+)"#,
            #"youtube\.com/shorts/([\w-]+)"#, // YouTube Shorts
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: url) {
                return String(url[range])
            }
        }
        return nil
    }
    
    // Извлечение YouTube URL из текста (включая Shorts)
    private func extractYouTubeURL(from text: String) -> String? {
        // Поддерживаемые форматы YouTube URL
        let patterns = [
            // Стандартный формат: https://www.youtube.com/watch?v=VIDEO_ID
            "https://(www\\.)?youtube\\.com/watch\\?v=[\\w-]+",
            // Короткий формат: https://youtu.be/VIDEO_ID
            "https://youtu\\.be/[\\w-]+",
            // Мобильный формат: https://m.youtube.com/watch?v=VIDEO_ID
            "https://m\\.youtube\\.com/watch\\?v=[\\w-]+",
            // YouTube Shorts: https://www.youtube.com/shorts/VIDEO_ID
            "https://(www\\.)?youtube\\.com/shorts/[\\w-]+",
            // Мобильный Shorts: https://m.youtube.com/shorts/VIDEO_ID
            "https://m\\.youtube\\.com/shorts/[\\w-]+",
            // С дополнительными параметрами: https://www.youtube.com/watch?v=VIDEO_ID&t=123
            "https://(www\\.)?youtube\\.com/watch\\?v=[\\w-]+[^\\s]*",
            // Shorts с параметрами: https://www.youtube.com/shorts/VIDEO_ID?feature=share
            "https://(www\\.)?youtube\\.com/shorts/[\\w-]+[^\\s]*"
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range, in: text) {
                var url = String(text[range])
                
                // Нормализуем URL: убираем лишние параметры, оставляем только v=
                if url.contains("youtube.com/watch") {
                    if let videoIdRange = url.range(of: #"v=[\w-]+"#, options: .regularExpression) {
                        let videoId = String(url[videoIdRange])
                        url = "https://www.youtube.com/watch?\(videoId)"
                    }
                } else if url.contains("youtu.be/") {
                    // Нормализуем короткие ссылки до полного формата
                    // Извлекаем video ID из youtu.be/VIDEO_ID
                    if let match = try? NSRegularExpression(pattern: #"youtu\.be/([\w-]+)"#).firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
                       match.numberOfRanges > 1,
                       let range = Range(match.range(at: 1), in: url) {
                        let videoId = String(url[range])
                        url = "https://www.youtube.com/watch?v=\(videoId)"
                    }
                } else if url.contains("youtube.com/shorts/") {
                    // Нормализуем Shorts URL до стандартного формата
                    // Извлекаем video ID из youtube.com/shorts/VIDEO_ID
                    if let match = try? NSRegularExpression(pattern: #"youtube\.com/shorts/([\w-]+)"#).firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
                       match.numberOfRanges > 1,
                       let range = Range(match.range(at: 1), in: url) {
                        let videoId = String(url[range])
                        url = "https://www.youtube.com/watch?v=\(videoId)"
                    }
                }
                
                return url
            }
        }
        return nil
    }
    
    // Отправка сообщения в Telegram
    private func sendTelegramMessage(token: String, chatId: Int64, text: String, client: Client) async throws {
        struct TelegramMessagePayload: Content {
            let chat_id: Int64
            let text: String
        }
        
        let payload = TelegramMessagePayload(chat_id: chatId, text: text)
        let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
        
        do {
        let response = try await client.post(url) { req in
            // Увеличиваем таймаут для запроса к Telegram API
            req.timeout = .seconds(30)
            try req.content.encode(payload, as: .json)
            }.get()
        
        guard response.status == .ok else {
            // Логируем ошибку для отладки
                var errorDetails = "Status: \(response.status)"
            if let body = response.body {
                let data = body.getData(at: 0, length: body.readableBytes) ?? Data()
                    if let bodyString = String(data: data, encoding: .utf8) {
                        errorDetails += " - \(bodyString)"
                        print("❌ Failed to send Telegram message: \(errorDetails)")
                    } else {
                        print("❌ Failed to send Telegram message: \(errorDetails) - Could not decode body")
                    }
            } else {
                    print("❌ Failed to send Telegram message: \(errorDetails) - No response body")
            }
                throw Abort(.badRequest, reason: "Failed to send message: \(errorDetails)")
        }
        
        // Логируем успешную отправку для отладки
        if let body = response.body {
            let data = body.getData(at: 0, length: body.readableBytes) ?? Data()
            if let bodyString = String(data: data, encoding: .utf8) {
                print("✅ Telegram message sent successfully: \(bodyString.prefix(200))")
            }
            }
        } catch {
            print("❌ Exception in sendTelegramMessage: \(error)")
            throw error
        }
    }
    
    /// Отправляет typing indicator (показывает, что бот печатает)
    private func sendTypingIndicator(token: String, chatId: Int64, client: Client) async throws {
        let url = URI(string: "https://api.telegram.org/bot\(token)/sendChatAction")
        struct ChatActionPayload: Content {
            let chat_id: Int64
            let action: String
        }
        let payload = ChatActionPayload(chat_id: chatId, action: "typing")
        _ = try await client.post(url) { req in
            try req.content.encode(payload, as: .json)
        }.get()
    }
    
    /// Отправляет саммари с разбиением на части, если сообщение слишком длинное
    /// Telegram имеет лимит 4096 символов на сообщение
    private func sendSummaryMessage(
        token: String,
        chatId: Int64,
        summary: String,
        client: Client,
        logger: Logger
    ) async throws {
        let maxMessageLength = 4000 // Оставляем запас
        let header = "📝 Краткое содержание видео:\n\n"
        
        if summary.count + header.count <= maxMessageLength {
            // Сообщение помещается в один раз
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: "\(header)\(summary)",
                client: client
            )
        } else {
            // Разбиваем на части
            let parts = splitTextIntoParts(text: summary, maxLength: maxMessageLength - header.count)
            
            // Отправляем первую часть с заголовком
            if let firstPart = parts.first {
                _ = try? await sendTelegramMessage(
                    token: token,
                    chatId: chatId,
                    text: "\(header)\(firstPart)",
                    client: client
                )
                
                // Небольшая задержка между сообщениями
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 секунды
            }
            
            // Отправляем остальные части
            for (index, part) in parts.dropFirst().enumerated() {
                let partHeader = "📝 (продолжение \(index + 2)/\(parts.count))\n\n"
                _ = try? await sendTelegramMessage(
                    token: token,
                    chatId: chatId,
                    text: "\(partHeader)\(part)",
                    client: client
                )
                
                // Небольшая задержка между сообщениями
                if index < parts.count - 2 {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 секунды
                }
            }
            
            logger.info("✅ Summary sent in \(parts.count) parts")
        }
    }
    
    /// Получает длительность видео в минутах через yt-dlp
    private func getVideoDuration(videoUrl: String, logger: Logger) async throws -> Int {
        // Проверяем наличие yt-dlp
        let ytdlpPaths = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "yt-dlp"]
        var ytdlpPath: String?
        
        for path in ytdlpPaths {
            if FileManager.default.fileExists(atPath: path) || path == "yt-dlp" {
                ytdlpPath = path
                break
            }
        }
        
        guard let ytdlp = ytdlpPath else {
            throw Abort(.badRequest, reason: "yt-dlp not found")
        }
        
        // Запускаем yt-dlp для получения длительности
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytdlp)
        process.arguments = [
            "--js-runtimes", "node:/usr/bin/nodejs",
            "--get-duration",
            "--no-playlist",
            videoUrl
        ]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // Игнорируем stderr
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw Abort(.badRequest, reason: "Failed to get video duration")
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else {
            throw Abort(.badRequest, reason: "Empty duration output")
        }
        
        // Парсим длительность в формате HH:MM:SS или MM:SS
        let components = output.split(separator: ":")
        guard components.count >= 2 else {
            throw Abort(.badRequest, reason: "Invalid duration format")
        }
        
        var totalSeconds = 0
        if components.count == 3 {
            // Формат HH:MM:SS
            let hours = Int(components[0]) ?? 0
            let minutes = Int(components[1]) ?? 0
            let seconds = Int(components[2]) ?? 0
            totalSeconds = hours * 3600 + minutes * 60 + seconds
        } else if components.count == 2 {
            // Формат MM:SS
            let minutes = Int(components[0]) ?? 0
            let seconds = Int(components[1]) ?? 0
            totalSeconds = minutes * 60 + seconds
        }
        
        let durationMinutes = Int(ceil(Double(totalSeconds) / 60.0))
        logger.info("📹 Video duration parsed: \(output) = \(durationMinutes) minutes")
        
        return durationMinutes
    }
    
    /// Разбивает текст на части по максимальной длине, стараясь разбивать по предложениям
    private func splitTextIntoParts(text: String, maxLength: Int) -> [String] {
        var parts: [String] = []
        var remaining = text
        
        while !remaining.isEmpty {
            if remaining.count <= maxLength {
                parts.append(remaining)
                break
            }
            
            // Пытаемся найти место разрыва по предложению (точка, восклицательный знак, вопросительный знак)
            let searchRange = remaining.startIndex..<remaining.index(remaining.startIndex, offsetBy: min(maxLength, remaining.count))
            let searchText = String(remaining[searchRange])
            
            // Ищем последнее предложение в пределах лимита
            let sentenceEnders = [". ", "! ", "? ", ".\n", "!\n", "?\n"]
            var breakIndex: String.Index?
            
            for ender in sentenceEnders {
                if let range = searchText.range(of: ender, options: .backwards) {
                    let potentialBreak = remaining.index(remaining.startIndex, offsetBy: searchText.distance(from: searchText.startIndex, to: range.upperBound))
                    if remaining.distance(from: remaining.startIndex, to: potentialBreak) <= maxLength {
                        breakIndex = potentialBreak
                        break
                    }
                }
            }
            
            // Если не нашли подходящее место, разбиваем по пробелу
            if breakIndex == nil {
                if let spaceRange = searchText.range(of: " ", options: .backwards) {
                    breakIndex = remaining.index(remaining.startIndex, offsetBy: searchText.distance(from: searchText.startIndex, to: spaceRange.upperBound))
                } else {
                    // Если даже пробела нет, просто режем по лимиту
                    breakIndex = remaining.index(remaining.startIndex, offsetBy: maxLength)
                }
            }
            
            guard let breakIdx = breakIndex else {
                // Fallback: просто режем
                let part = String(remaining.prefix(maxLength))
                parts.append(part)
                remaining = String(remaining.dropFirst(maxLength))
                continue
            }
            
            let part = String(remaining[..<breakIdx]).trimmingCharacters(in: .whitespaces)
            if !part.isEmpty {
                parts.append(part)
            }
            remaining = String(remaining[breakIdx...]).trimmingCharacters(in: .whitespaces)
        }
        
        return parts
    }
}
