import Vapor
import Foundation

final class FileNowBotController {
    // Rate limiter: 2 запроса/видео в минуту на пользователя
    private static let rateLimiter = RateLimiter(maxRequests: 2, timeWindow: 60)
    // Дедупликатор для предотвращения обработки дубликатов
    private static let updateDeduplicator = UpdateDeduplicator()
    
    func handleWebhook(_ req: Request) async throws -> Response {
        req.logger.info("═══════════════════════════════════════════════")
        req.logger.info("🔔 FileNowBot webhook hit!")
        req.logger.info("Method: \(req.method), Path: \(req.url.path)")
        
        let token = Environment.get("FILENOWBOT_TOKEN")
        guard let token = token, token.isEmpty == false else {
            req.logger.error("FILENOWBOT_TOKEN is missing")
            return Response(status: .internalServerError)
        }

        let rawBody = req.body.string ?? ""
        req.logger.info("📦 Raw body length: \(rawBody.count) characters")
        if rawBody.count > 0 && rawBody.count < 500 {
            req.logger.debug("Raw body: \(rawBody)")
        }

        req.logger.info("🔍 Decoding FileNowBotUpdate...")
        let update = try? req.content.decode(FileNowBotUpdate.self)
        guard let safeUpdate = update else {
            req.logger.error("❌ Failed to decode FileNowBotUpdate - check raw body above")
            return Response(status: .ok)
        }
        req.logger.info("✅ FileNowBotUpdate decoded successfully")
        
        // Проверяем дедупликацию: если этот update_id уже обработан, игнорируем
        let updateId = safeUpdate.update_id
        req.logger.info("🔍 Checking duplicate for update_id=\(updateId)")
        let isDuplicate = await Self.updateDeduplicator.checkAndAdd(updateId: updateId)
        if isDuplicate {
            req.logger.info("⚠️ Duplicate update_id \(updateId) - already processed, ignoring")
            return Response(status: .ok)
        }
        req.logger.info("✅ Update_id \(updateId) is new, processing...")

        guard let message = safeUpdate.message else {
            req.logger.warning("⚠️ No message in update (update_id: \(updateId))")
            return Response(status: .ok)
        }
        
        let text = message.text ?? ""
        let chatId = message.chat.id
        // В приватных чатах chat.id == user.id
        let userId = chatId
        
        req.logger.info("📨 Incoming message - chatId=\(chatId), text length=\(text.count)")
        if !text.isEmpty {
            req.logger.info("📝 Message text: \(text.prefix(200))")
        }

        // Регистрируем пользователя в общей базе монетизации
        MonetizationService.registerUser(
            botName: "filenowbot",
            chatId: chatId,
            logger: req.logger,
            env: req.application.environment
        )
        
        // Если пользователь нажал кнопку "Я подписался, проверить" —
        // повторно проверяем подписку и либо разблокируем, либо снова показываем требование.
        if text == "✅ Я подписался, проверить" {
            let (allowed, channels) = await MonetizationService.checkAccess(
                botName: "filenowbot",
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
                // Проверяем, есть ли сохраненная ссылка
                if let savedUrl = await UrlSessionManager.shared.getUrl(userId: userId) {
                    // Есть сохраненная ссылка - автоматически обрабатываем её
                    await UrlSessionManager.shared.clearUrl(userId: userId)
                    
                    // Проверяем rate limit
                    let canProceed = await Self.rateLimiter.checkLimit(for: chatId)
                    
                    if !canProceed {
                        _ = try? await sendTelegramMessage(
                            token: token,
                            chatId: chatId,
                            text: "Ты уже прислал две ссылки за последнюю минуту. Подожди 1 минуту и пришли ссылку снова",
                            client: req.client,
                            logger: req.logger
                        )
                        return Response(status: .ok)
                    }
                    
                    // Отправляем сообщение о начале обработки
                    _ = try? await sendTelegramMessage(
                        token: token,
                        chatId: chatId,
                        text: "Обрабатываю сохраненную ссылку... 🎬",
                        client: req.client,
                        logger: req.logger
                    )
                    
                    // Обрабатываем ссылку
                    let client = req.client
                    let logger = req.logger
                    
                    // Определяем тип ссылки
                    let videoType: VideoType
                    if extractTikTokURL(from: savedUrl) != nil {
                        videoType = .tiktok
                    } else if extractYouTubeShortsURL(from: savedUrl) != nil {
                        videoType = .youtubeShorts
                    } else {
                        logger.error("❌ Unknown video type for saved URL: \(savedUrl)")
                        _ = try? await sendTelegramMessage(
                            token: token,
                            chatId: chatId,
                            text: "😔 Не удалось определить тип ссылки. Попробуй отправить ссылку снова 💕",
                            client: client,
                            logger: logger
                        )
                        return Response(status: .ok)
                    }
                    
                    do {
                        logger.info("🚀 Processing saved \(videoType == .tiktok ? "TikTok" : "YouTube Shorts") URL: \(savedUrl)")
                        logger.info("🔧 Extracting video URL via resolver...")
                        let directVideoUrl = try await extractVideoUrl(from: savedUrl, type: videoType, req: req)
                        logger.info("✅ Video URL extracted: \(directVideoUrl.prefix(200))...")
                        
                        try await sendTelegramVideoByUrl(
                            token: token,
                            chatId: chatId,
                            videoUrl: directVideoUrl,
                            client: client,
                            logger: logger
                        )
                        logger.info("✅ Video sent successfully")
                    } catch {
                        logger.error("❌ Error processing \(videoType == .tiktok ? "TikTok" : "YouTube Shorts") video: \(error)")
                        
                        // Проверяем, является ли ошибка отказом всех провайдеров TikTok
                        if videoType == .tiktok,
                           let resolverError = error as? TikTokResolver.TikTokResolverError,
                           case .allProvidersFailed(let providers) = resolverError {
                            logger.warning("⚠️ All TikTok providers failed: \(providers.joined(separator: ", "))")
                            _ = try? await sendTelegramMessage(
                                token: token,
                                chatId: chatId,
                                text: "⏸️ Временно недоступно\n\nСервисы для скачивания TikTok перегружены или временно недоступны.\nПопробуй позже, пожалуйста.",
                                client: client,
                                logger: logger
                            )
                        } else {
                            _ = try? await sendTelegramMessage(
                                token: token,
                                chatId: chatId,
                                text: "😔 Произошла ошибка при обработке видео. Попробуй ещё раз 💕",
                                client: client,
                                logger: logger
                            )
                        }
                    }
                    
                    return Response(status: .ok)
                } else {
                    // Нет сохраненной ссылки - показываем обычное сообщение
                    let successText = "Можешь отправить ссылку на TikTok или YouTube Shorts видео, и я верну его без ватермарки."
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
            req.logger.info("✅ Command /start received for chatId=\(chatId)")
            do {
                req.logger.info("📤 Sending /start welcome message...")
                try await sendTelegramMessage(
                    token: token,
                    chatId: message.chat.id,
                    text: "Привет! 👋\n\nЯ бот для скачивания TikTok и YouTube Shorts видео без водяного знака! 🎬\n\nПросто отправь мне ссылку на видео, и я верну его тебе без ватермарки.\n\nПоддерживаются ссылки:\n• TikTok: https://www.tiktok.com/...\n• TikTok: https://vm.tiktok.com/...\n• YouTube Shorts: https://www.youtube.com/shorts/...",
                    client: req.client,
                    logger: req.logger
                )
                req.logger.info("✅ /start message sent successfully")
            } catch {
                req.logger.error("❌ Failed to send /start message: \(error)")
                req.logger.error("❌ Error details: \(error.localizedDescription)")
            }
            return Response(status: .ok)
        }

        // Проверяем наличие TikTok или YouTube Shorts URL в сообщении
        let videoUrl: String?
        let videoType: VideoType
        
        req.logger.info("🔍 Checking for TikTok URL in text: \(text.prefix(200))")
        if let tiktokUrl = extractTikTokURL(from: text) {
            videoUrl = tiktokUrl
            videoType = .tiktok
            req.logger.info("✅ Detected TikTok URL: \(tiktokUrl)")
        } else {
            req.logger.info("❌ TikTok URL not found, checking YouTube Shorts...")
            req.logger.info("🔍 Checking for YouTube Shorts URL in text: \(text.prefix(200))")
            if let youtubeUrl = extractYouTubeShortsURL(from: text) {
                videoUrl = youtubeUrl
                videoType = .youtubeShorts
                req.logger.info("✅ Detected YouTube Shorts URL: \(youtubeUrl)")
            } else {
                req.logger.info("ℹ️ No video URL found in message (text: \(text.prefix(100)))")
                // Отправляем сообщение с инструкцией, если это не ссылка и не команда
                if !text.isEmpty && !text.hasPrefix("/") {
                    _ = try? await sendTelegramMessage(
                        token: token,
                        chatId: message.chat.id,
                        text: "Привет! 👋 Отправь мне ссылку на TikTok или YouTube Shorts видео, и я верну его без водяного знака! 🎬",
                        client: req.client,
                        logger: req.logger
                    )
                }
                return Response(status: .ok)
            }
        }
        
        guard let url = videoUrl else {
            return Response(status: .ok)
        }

        // Проверка rate limit
        let canProceed = await Self.rateLimiter.checkLimit(for: chatId)
        
        if !canProceed {
            req.logger.warning("⚠️ Rate limit exceeded for user \(chatId)")
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: "Ты уже прислал две ссылки за последнюю минуту. Подожди 1 минуту и пришли ссылку снова",
                client: req.client,
                logger: req.logger
            )
            return Response(status: .ok)
        }

        // Проверяем подписку перед обработкой ссылки
        let (subscriptionAllowed, channels) = await MonetizationService.checkAccess(
            botName: "filenowbot",
            userId: userId,
            logger: req.logger,
            env: req.application.environment,
            client: req.client
        )
        
        guard subscriptionAllowed else {
            // Пользователь не подписан - сохраняем ссылку и отправляем сообщение с требованием подписки
            await UrlSessionManager.shared.saveUrl(userId: userId, url: url)
            try await sendSubscriptionRequiredMessage(
                chatId: chatId,
                channels: channels,
                token: token,
                req: req
            )
            return Response(status: .ok)
        }

        // Выполняем обработку (дедупликация уже предотвратит повторную обработку)
        let client = req.client
        let logger = req.logger

        do {
            logger.info("🚀 Processing \(videoType == .tiktok ? "TikTok" : "YouTube Shorts") URL: \(url)")
            
            // Отправляем уведомление о начале скачивания
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: "⏳ Скачиваю видео, подожди немного...",
                client: client,
                logger: logger
            )
            
            if videoType == .youtubeShorts {
                // Для YouTube Shorts сразу используем прямой download через yt-dlp (быстрее и надежнее)
                logger.info("📥 Using yt-dlp direct download for YouTube Shorts...")
                try await sendTelegramVideoByYtDlp(
                    token: token,
                    chatId: chatId,
                    originalUrl: url,
                    client: client,
                    logger: logger
                )
            } else {
                // Для TikTok используем резолвер с публичными API
                logger.info("🔧 Extracting video URL via resolver...")
                let directVideoUrl = try await extractVideoUrl(from: url, type: videoType, req: req)
                logger.info("✅ Video URL extracted: \(directVideoUrl.prefix(200))...")
                
                try await sendTelegramVideoByUrl(
                    token: token,
                    chatId: chatId,
                    videoUrl: directVideoUrl,
                    client: client,
                    logger: logger
                )
            }
            logger.info("✅ Video sent successfully")
            
            // Очищаем сохраненную ссылку после успешной обработки
            await UrlSessionManager.shared.clearUrl(userId: userId)
        } catch {
            logger.error("❌ Error processing \(videoType == .tiktok ? "TikTok" : "YouTube Shorts") video: \(error)")
            
            // Проверяем, является ли ошибка отказом всех провайдеров TikTok
            if videoType == .tiktok,
               let resolverError = error as? TikTokResolver.TikTokResolverError,
               case .allProvidersFailed(let providers) = resolverError {
                logger.warning("⚠️ All TikTok providers failed: \(providers.joined(separator: ", "))")
                _ = try? await sendTelegramMessage(
                    token: token,
                    chatId: chatId,
                    text: "⏸️ Временно недоступно\n\nПохоже что все провайдеры для скачивания TikTok перегружены или временно недоступны.\nПришли ссылку позже",
                    client: client,
                    logger: logger
                )
            } else {
                _ = try? await sendTelegramMessage(
                    token: token,
                    chatId: chatId,
                    text: "😔 Произошла ошибка при обработке видео. Попробуй ещё раз",
                    client: client,
                    logger: logger
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
    
    // MARK: - Обработка видео ссылок
    
    enum VideoType {
        case tiktok
        case youtubeShorts
    }
    
    // Извлечение TikTok URL из текста
    private func extractTikTokURL(from text: String) -> String? {
        let patterns = [
            "https://www\\.tiktok\\.com/[^\\s]+",
            "https://vm\\.tiktok\\.com/[^\\s]+",
            "https://vt\\.tiktok\\.com/[^\\s]+",
            "https://tiktok\\.com/[^\\s]+"
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range, in: text) {
                return String(text[range])
            }
        }
        return nil
    }
    
    // Извлечение YouTube Shorts URL из текста
    private func extractYouTubeShortsURL(from text: String) -> String? {
        let patterns = [
            "https://www\\.youtube\\.com/shorts/[^\\s]+",
            "https://youtube\\.com/shorts/[^\\s]+",
            "https://m\\.youtube\\.com/shorts/[^\\s]+"
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range, in: text) {
                let url = String(text[range])
                // Проверяем наличие /shorts/ в URL
                if url.contains("/shorts/") {
                    return url
                }
            }
        }
        return nil
    }
    
    // Универсальная функция извлечения прямого URL на видео
    private func extractVideoUrl(from url: String, type: VideoType, req: Request) async throws -> String {
        switch type {
        case .tiktok:
            let resolver = TikTokResolver(client: req.client, logger: req.logger)
            return try await resolver.resolveDirectVideoUrl(from: url)
        case .youtubeShorts:
            let resolver = YouTubeShortsResolver(client: req.client, logger: req.logger)
            return try await resolver.resolveDirectVideoUrl(from: url)
        }
    }
    
    // Отправка сообщения в Telegram (POST с JSON)
    private func sendTelegramMessage(token: String, chatId: Int64, text: String, client: Client, logger: Logger) async throws {
        struct SendMessagePayload: Content {
            let chat_id: Int64
            let text: String
            let parse_mode: String?
        }
        
        let payload = SendMessagePayload(
            chat_id: chatId,
            text: text,
            parse_mode: nil
        )
        
        let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
        let response = try await client.post(url) { req in
            try req.content.encode(payload, as: .json)
        }.get()
        
        guard response.status == .ok else {
            if let body = response.body {
                let data = body.getData(at: 0, length: body.readableBytes) ?? Data()
                if let errorStr = String(data: data, encoding: .utf8) {
                    logger.error("Telegram API error: \(errorStr)")
                }
            }
            throw Abort(.badRequest, reason: "Failed to send message")
        }
    }
    
    // Отправка видео по прямой ссылке через Telegram API
    // Сначала скачиваем видео на сервер, затем отправляем как файл
    private func sendTelegramVideoByUrl(token: String, chatId: Int64, videoUrl: String, client: Client, logger: Logger) async throws {
        logger.info("📥 Downloading video from URL: \(videoUrl.prefix(100))...")
        
        // Скачиваем видео на сервер с правильными заголовками
        let videoUri = URI(string: videoUrl)
        var downloadRequest = ClientRequest(method: .GET, url: videoUri)
        
        // Добавляем заголовки для YouTube/Google CDN
        downloadRequest.headers.add(name: "User-Agent", value: "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
        if videoUrl.contains("googlevideo.com") || videoUrl.contains("youtube.com") {
            downloadRequest.headers.add(name: "Referer", value: "https://www.youtube.com/")
            downloadRequest.headers.add(name: "Origin", value: "https://www.youtube.com")
        }
        
        let downloadResponse = try await client.send(downloadRequest)
        
        guard downloadResponse.status == .ok, let videoBody = downloadResponse.body else {
            let statusCode = downloadResponse.status.code
            logger.error("❌ Failed to download video: status \(statusCode)")
            throw Abort(.badRequest, reason: "Failed to download video from URL (status: \(statusCode))")
        }
        
        let videoData = videoBody.getData(at: 0, length: videoBody.readableBytes) ?? Data()
        logger.info("✅ Video downloaded, size: \(videoData.count) bytes")
        
        // Отправляем видео как файл через Telegram API (используем данные из памяти, файл не нужен)
        let url = URI(string: "https://api.telegram.org/bot\(token)/sendVideo")
        let boundary = UUID().uuidString
        var body = ByteBufferAllocator().buffer(capacity: 0)
        
        // chat_id
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n")
        body.writeString("\(chatId)\r\n")
        
        // video file
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"video\"; filename=\"video.mp4\"\r\n")
        body.writeString("Content-Type: video/mp4\r\n\r\n")
        body.writeBytes(videoData)
        body.writeString("\r\n")
        body.writeString("--\(boundary)--\r\n")
        
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "multipart/form-data; boundary=\(boundary)")
        
        var request = ClientRequest(method: .POST, url: url)
        request.headers = headers
        request.body = body
        let response = try await client.send(request)
        
        guard response.status == .ok else {
            if let responseBody = response.body {
                let errorData = responseBody.getData(at: 0, length: responseBody.readableBytes) ?? Data()
                if let errorStr = String(data: errorData, encoding: .utf8) {
                    logger.error("Telegram API error: \(errorStr)")
                    throw Abort(.badRequest, reason: "Failed to send video: \(errorStr)")
                }
            }
            throw Abort(.badRequest, reason: "Failed to send video")
        }
        
        logger.info("✅ Video sent via Telegram API")
    }
    
    // Отправка видео через прямой download через yt-dlp (для YouTube Shorts)
    private func sendTelegramVideoByYtDlp(token: String, chatId: Int64, originalUrl: String, client: Client, logger: Logger) async throws {
        logger.info("📥 Downloading video via yt-dlp from: \(originalUrl)")
        
        // Находим yt-dlp (универсальный поиск для Mac и Linux/VPS)
        let ytdlpPaths = [
            "/opt/homebrew/bin/yt-dlp",  // macOS Homebrew (Apple Silicon)
            "/usr/local/bin/yt-dlp",      // macOS Homebrew (Intel) / Linux
            "/usr/bin/yt-dlp",            // Linux стандартный путь
            "/bin/yt-dlp",                // Linux альтернативный путь
            "yt-dlp"                      // Через PATH (если установлен глобально)
        ]
        
        var ytDlpPath: String?
        for path in ytdlpPaths {
            if FileManager.default.fileExists(atPath: path) || path == "yt-dlp" {
                logger.info("🔍 Found yt-dlp at: \(path)")
                ytDlpPath = path
                break
            }
        }
        
        guard let ytdlp = ytDlpPath else {
            throw Abort(.badRequest, reason: "yt-dlp not found. Install it: brew install yt-dlp (Mac) or apt install yt-dlp (Linux)")
        }
        
        // Создаем временный файл
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("\(UUID().uuidString).mp4")
        
        defer {
            // Удаляем временный файл после использования
            try? FileManager.default.removeItem(at: tempFile)
        }
        
        // Запускаем yt-dlp для скачивания видео
        // Используем формат без HLS (m3u8), так как YouTube блокирует HLS фрагменты на VPS
        // Приоритет: 1080p (bestvideo+bestaudio) -> 720p (bestvideo+bestaudio) -> готовое видео
        // player_client=tv,android — клиенты, которые реже дают 403 (web требует PO token / JS runtime)
        // Deno в контейнере даёт yt-dlp JS runtime для YouTube при необходимости
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytdlp)
        process.arguments = [
            "--js-runtimes", "deno:/usr/local/bin/deno",
            "--extractor-args", "youtube:player_client=tv,android",
            "-f", "bestvideo[height=1080][vcodec^=avc1][ext=mp4][protocol!=m3u8]+bestaudio[ext=m4a]/bestvideo[height=720][vcodec^=avc1][ext=mp4][protocol!=m3u8]+bestaudio[ext=m4a]/bestvideo[height<=1080][vcodec^=avc1][ext=mp4][protocol!=m3u8]+bestaudio[ext=m4a]/best[vcodec^=avc1][ext=mp4][protocol!=m3u8]/best[ext=mp4][protocol!=m3u8]/best",
            "--merge-output-format", "mp4",
            "--postprocessor-args", "ffmpeg:-movflags +faststart -c:v copy -c:a copy",
            "--user-agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "-o", tempFile.path,
            originalUrl
        ]
        
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = errorPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            guard process.terminationStatus == 0 else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                if let errorStr = String(data: errorData, encoding: .utf8) {
                    logger.error("yt-dlp error: \(errorStr)")
                }
                throw Abort(.badRequest, reason: "yt-dlp download failed")
            }
            
            // Проверяем, что файл создан
            guard FileManager.default.fileExists(atPath: tempFile.path) else {
                throw Abort(.badRequest, reason: "yt-dlp did not create output file")
            }
            
            // Читаем видео из файла
            let videoData = try Data(contentsOf: tempFile)
            logger.info("✅ Video downloaded via yt-dlp, size: \(videoData.count) bytes")
            
            // Отправляем видео в Telegram
            let url = URI(string: "https://api.telegram.org/bot\(token)/sendVideo")
            let boundary = UUID().uuidString
            var body = ByteBufferAllocator().buffer(capacity: 0)
            
            // chat_id
            body.writeString("--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n")
            body.writeString("\(chatId)\r\n")
            
            // video file
            body.writeString("--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"video\"; filename=\"video.mp4\"\r\n")
            body.writeString("Content-Type: video/mp4\r\n\r\n")
            body.writeBytes(videoData)
            body.writeString("\r\n")
            body.writeString("--\(boundary)--\r\n")
            
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "multipart/form-data; boundary=\(boundary)")
            
            var request = ClientRequest(method: .POST, url: url)
            request.headers = headers
            request.body = body
            let response = try await client.send(request)
            
            guard response.status == .ok else {
                if let responseBody = response.body {
                    let errorData = responseBody.getData(at: 0, length: responseBody.readableBytes) ?? Data()
                    if let errorStr = String(data: errorData, encoding: .utf8) {
                        logger.error("Telegram API error: \(errorStr)")
                        throw Abort(.badRequest, reason: "Failed to send video: \(errorStr)")
                    }
                }
                throw Abort(.badRequest, reason: "Failed to send video")
            }
            
            logger.info("✅ Video sent via Telegram API (yt-dlp)")
        } catch {
            logger.error("❌ yt-dlp download failed: \(error)")
            throw error
        }
    }
}

