import Vapor
import Foundation
import Fluent

final class NeurfotobotController: Sendable {
    private let minimumPhotoCount = 5
    private let maximumPhotoCount = 10
    
    // Rate limiters для защиты от злоупотребления
    // 1. Обучение модели: не больше 1 в час на пользователя
    private static let trainingRateLimiter = RateLimiter(maxRequests: 1, timeWindow: 3600) // 1 час
    
    // 2. Генерация фото: не больше 2 в минуту на пользователя
    private static let generationRateLimiter = RateLimiter(maxRequests: 2, timeWindow: 60) // 1 минута
    
    // 3. Генерация фото: не больше 50 в сутки на пользователя
    private static let generationDailyLimiter = DailyLimiter()

    func handleWebhook(_ req: Request) async throws -> Response {
        guard let token = Environment.get("NEURFOTOBOT_TOKEN"), !token.isEmpty else {
            req.logger.error("NEURFOTOBOT_TOKEN is missing")
            return Response(status: .internalServerError)
        }

        guard let update = try? req.content.decode(NeurfotobotUpdate.self) else {
            req.logger.warning("Failed to decode NeurfotobotUpdate")
            return Response(status: .ok)
        }

        if let callback = update.callback_query {
            // Обновляем время последней активности для callback'ов
            let chatId: Int64
            if let messageChatId = callback.message?.chat.id {
                chatId = messageChatId
            } else {
                chatId = callback.from.id
            }
            await PhotoSessionManager.shared.setLastActivity(for: chatId)
            
            try await handleCallback(callback, token: token, req: req)
            return Response(status: .ok)
        }

        guard let message = update.message else {
            req.logger.info("No message payload in update \(update.update_id)")
            return Response(status: .ok)
        }

        // Регистрируем пользователя в общей базе монетизации
        // В личных чатах chat.id равен user.id
        MonetizationService.registerUser(
            botName: "Neurfotobot",
            chatId: message.chat.id,
            logger: req.logger,
            env: req.application.environment
        )
        
        // Обновляем время последней активности
        await PhotoSessionManager.shared.setLastActivity(for: message.chat.id)

        let text = message.text ?? ""
        
        // Если пользователь нажал кнопку "Я подписался, проверить" —
        // повторно проверяем подписку и либо разблокируем, либо снова показываем требование.
        if text == "✅ Я подписался, проверить" {
            // В личных чатах chat.id равен user.id
            let (allowed, channels) = await MonetizationService.checkAccess(
                botName: "Neurfotobot",
                userId: message.chat.id,
                logger: req.logger,
                env: req.application.environment,
                client: req.client
            )

            if allowed {
                // Удаляем клавиатуру "✅ Я подписался, проверить" после успешной проверки
                struct ReplyKeyboardRemove: Content {
                    let remove_keyboard: Bool
                }
                
                struct RemoveKeyboardPayload: Content {
                    let chat_id: Int64
                    let text: String
                    let disable_web_page_preview: Bool
                    let reply_markup: ReplyKeyboardRemove?
                }
                
                let removeKeyboard = ReplyKeyboardRemove(remove_keyboard: true)
                let removePayload = RemoveKeyboardPayload(
                    chat_id: message.chat.id,
                    text: "Подписка подтверждена ✅",
                    disable_web_page_preview: false,
                    reply_markup: removeKeyboard
                )
                
                let sendMessageUrl = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
                _ = try? await req.client.post(sendMessageUrl) { sendReq in
                    try sendReq.content.encode(removePayload, as: .json)
                }.get()
                
                // Проверяем, был ли промпт готов к генерации (состояние readyToGenerate)
                let promptState = await PhotoSessionManager.shared.getPromptCollectionState(for: message.chat.id)
                if promptState == .readyToGenerate {
                    // Промпт был готов - запускаем генерацию автоматически
                    _ = try? await sendTelegramMessage(
                        token: token,
                        chatId: message.chat.id,
                        text: "Запускаю генерацию...",
                        client: req.client
                    )
                    try await finalizeAndGeneratePrompt(chatId: message.chat.id, token: token, req: req)
                } else {
                    // Промпт не был готов - отправляем обычное сообщение
                let successText = "Можешь обучить модель нажав /train или добавить ещё фотографии"
                _ = try? await sendTelegramMessage(
                    token: token,
                    chatId: message.chat.id,
                    text: successText,
                    client: req.client
                )
                }
                return Response(status: .ok)
            } else {
                // Подписка всё ещё не подтверждена
                try await sendSubscriptionRequiredMessage(
                    token: token,
                    chatId: message.chat.id,
                    channels: channels,
                    client: req.client
                )
                return Response(status: .ok)
            }
        }
        
        if text == "/start" {
            // Не сбрасываем сессию при /start, чтобы сохранить модель если она есть
            var modelVersion = await PhotoSessionManager.shared.getModelVersion(for: message.chat.id)
            let photosCount = await PhotoSessionManager.shared.getPhotos(for: message.chat.id).count
            
            // Если модели нет в памяти, проверяем базу данных
            if modelVersion == nil {
                do {
                    if let userModel = try await UserModel.query(on: req.db)
                        .filter(\.$chatId == message.chat.id)
                        .first() {
                        modelVersion = userModel.modelVersion
                        await PhotoSessionManager.shared.setModelVersion(userModel.modelVersion, for: message.chat.id)
                        await PhotoSessionManager.shared.setTriggerWord(userModel.triggerWord, for: message.chat.id)
                        await PhotoSessionManager.shared.setTrainingState(.ready, for: message.chat.id)
                        req.logger.info("Restored model version \(userModel.modelVersion) for chatId=\(message.chat.id) from database")
                    }
                } catch {
                    req.logger.warning("Failed to check database for model version: \(error)")
                }
            }
            
            let welcomeMessage: String
            let keyboard: [[InlineKeyboardButton]]
            
            if modelVersion != nil {
                // У пользователя есть модель
                welcomeMessage = """
Привет! Твоя модель уже обучена и готова к работе! 🎨

Можешь сразу описать образ или использовать кнопки ниже.
"""
                keyboard = [
                    [InlineKeyboardButton(text: "📝 Составить промпт", callback_data: "start_generate")],
                    [InlineKeyboardButton(text: "ℹ️ Информация о модели", callback_data: "show_model_info")]
                ]
            } else if photosCount >= minimumPhotoCount {
                // У пользователя есть фото, но модель не обучена
                welcomeMessage = """
Привет! У тебя уже загружено \(photosCount) фото. Можешь обучить модель или добавить ещё фотографии.

Нужно от \(minimumPhotoCount) до \(maximumPhotoCount) фото для обучения.
"""
                keyboard = [
                    [InlineKeyboardButton(text: "🚀 Обучить модель", callback_data: "train_from_start")],
                    [InlineKeyboardButton(text: "📸 Добавить фото", callback_data: "add_photos")]
                ]
            } else {
                // Новый пользователь или мало фото
                welcomeMessage = """
Привет! Загрузи от пяти до десяти своих фотографий, где хорошо видно лицо. Я соберу модель за несколько минут и по твоему промпту верну фото с твоим участием!

⏳ Обычно всё готово за несколько минут. Мы сообщим, когда модель соберётся и можно будет придумать образ. Чтобы всем было комфортно, автоматически проверяем фотографии через SafeSearch, а промпты через OpenAI Moderation. Добросовестных пользователей это никак не затрагивает, но любой незаконный контент блокируется и фиксируется в логах
"""
                keyboard = [
                    [InlineKeyboardButton(text: "📸 Начать загрузку фото", callback_data: "start_upload")]
                ]
            }

            do {
                let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
                var request = ClientRequest(method: .POST, url: url)
                let payload = SendInlineMessagePayload(
                    chat_id: message.chat.id,
                    text: welcomeMessage,
                    reply_markup: ReplyMarkup(inline_keyboard: keyboard)
                )
                request.headers.add(name: .contentType, value: "application/json")
                request.body = try .init(data: JSONEncoder().encode(payload))
                _ = try await req.client.send(request)
            } catch {
                req.logger.error("Failed to send welcome message: \(error)")
            }
            return Response(status: .ok)
        }

        if text == "/train" {
            try await handleTrainCommand(chatId: message.chat.id, token: token, req: req)
            return Response(status: .ok)
        }

        if text == "/generate" {
            try await handleGenerateCommand(chatId: message.chat.id, token: token, req: req)
            return Response(status: .ok)
        }

        if !text.isEmpty && text != "/start" && text != "/model" && text != "/train" && text != "/generate" {
            do {
                try await handlePrompt(text: text, message: message, token: token, req: req)
            } catch {
                req.logger.error("Failed to process prompt: \(error)")
                _ = try? await sendTelegramMessage(
                    token: token,
                    chatId: message.chat.id,
                    text: "Не смогла обработать описание. Попробуй ещё раз позже, пожалуйста.",
                    client: req.client
                )
            }
            return Response(status: .ok)
        }

        if text == "/model" {
            try await handleModelCommand(chatId: message.chat.id, token: token, req: req)
            return Response(status: .ok)
        }

        if let photos = message.photo, !photos.isEmpty {
            do {
                try await handlePhotoMessage(photos: photos, message: message, token: token, req: req)
            } catch {
                req.logger.error("Failed to process photo: \(error)")
                _ = try? await sendTelegramMessage(
                    token: token,
                    chatId: message.chat.id,
                    text: "Не получилось обработать фото. Попробуй отправить его ещё раз, пожалуйста.",
                    client: req.client
                )
            }
            return Response(status: .ok)
        }

        return Response(status: .ok)
    }

    private func sendTelegramMessage(token: String, chatId: Int64, text: String, client: Client) async throws {
        let encodedText = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage?chat_id=\(chatId)&text=\(encodedText)")
        _ = try await client.get(url)
    }

    private func sendSubscriptionRequiredMessage(token: String, chatId: Int64, channels: [String], client: Client) async throws {
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
        _ = try await client.post(sendMessageUrl) { sendReq in
            try sendReq.content.encode(payload, as: .json)
        }.get()
    }

    private func handlePhotoMessage(photos: [NeurfotobotPhoto], message: NeurfotobotMessage, token: String, req: Request) async throws {
        let trainingState = await PhotoSessionManager.shared.getTrainingState(for: message.chat.id)
        switch trainingState {
        case .idle:
            break
        case .failed:
            await PhotoSessionManager.shared.reset(for: message.chat.id)
        case .training, .ready:
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: message.chat.id,
                text: "Сейчас модель уже обучается или готова. Дождись завершения, пожалуйста.",
                client: req.client
            )
            return
        }

        let existing = await PhotoSessionManager.shared.getPhotos(for: message.chat.id)
        guard existing.count < maximumPhotoCount else {
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: message.chat.id,
                text: "Я уже получила максимальные \(maximumPhotoCount) фотографий. Скоро вернусь с обновлениями!",
                client: req.client
            )
            return
        }

        let bestPhoto = photos.max(by: { ($0.file_size ?? 0) < ($1.file_size ?? 0) }) ?? photos[0]
        let fileInfo = try await fetchTelegramFileInfo(token: token, fileId: bestPhoto.file_id, client: req.client)
        guard let filePath = fileInfo.result.file_path else {
            throw Abort(.badRequest, reason: "Telegram file_path missing")
        }

        let fileData = try await downloadTelegramFile(token: token, filePath: filePath, client: req.client)

        // Проверка размера файла: максимум 5 МБ
        let maxFileSize = 5 * 1024 * 1024 // 5 МБ в байтах
        if fileData.count > maxFileSize {
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: message.chat.id,
                text: "Фото слишком большое (максимум 5 МБ)\n\nВыбери другое фото или уменьши его размер. Мне нужно от 5 до 10 фотографий для обучения модели",
                client: req.client
            )
            // Показываем кнопку для начала загрузки фото
            let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
            var request = ClientRequest(method: .POST, url: url)
            let payload = SendInlineMessagePayload(
                chat_id: message.chat.id,
                text: "Начни загрузку фото заново:",
                reply_markup: ReplyMarkup(inline_keyboard: [[InlineKeyboardButton(text: "📸 Начать загрузку фото", callback_data: "start_upload")]])
            )
            request.headers.add(name: .contentType, value: "application/json")
            request.body = try .init(data: JSONEncoder().encode(payload))
            _ = try await req.client.send(request)
            req.logger.info("File size limit exceeded for chatId=\(message.chat.id): \(fileData.count) bytes (max: \(maxFileSize) bytes)")
            return
        }

        // SafeSearch модерация перед сохранением (если включена)
        let safeSearchDisabled = Environment.get("DISABLE_SAFESEARCH")?.lowercased() == "true"
        let riskyLevels: Set<String> = ["LIKELY", "VERY_LIKELY"]
        if !safeSearchDisabled {
            do {
                let vision = try GoogleVisionClient(request: req)
                let annotation = try await vision.analyzeSafeSearch(data: fileData)
                if riskyLevels.contains(annotation.adult) ||
                    riskyLevels.contains(annotation.violence ?? "") ||
                    riskyLevels.contains(annotation.racy ?? "") ||
                    riskyLevels.contains(annotation.medical ?? "") {
                    req.logger.warning("SafeSearch blocked photo for chatId=\(message.chat.id)")
                    _ = try? await sendTelegramMessage(
                        token: token,
                        chatId: message.chat.id,
                        text: "Не могу сохранить это фото: оно не прошло модерацию SafeSearch. Попробуй другие снимки, пожалуйста.",
                        client: req.client
                    )
                    return
                }
            } catch {
                // Fail-open стратегия: при ошибке модерации продолжаем обработку
                req.logger.warning("SafeSearch check failed for chatId=\(message.chat.id): \(error). Proceeding without blocking the photo.")
            }
        } else {
            req.logger.warning("SafeSearch is disabled via DISABLE_SAFESEARCH env flag; skipping moderation for chat \(message.chat.id)")
        }

        let ext = (filePath as NSString).pathExtension.lowercased()
        let finalExt = ext.isEmpty ? "jpg" : ext

        // Сохраняем фото локально в NEURFOTOBOT_TEMP_DIR/photos/{chatId}/{uuid}.ext
        let relativePath = "photos/\(message.chat.id)/\(UUID().uuidString).\(finalExt)"
        let fileURL = try NeurfotobotTempDirectory.fileURL(relativePath: relativePath)
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fileData.write(to: fileURL)
        req.logger.info("Saved local photo for chatId=\(message.chat.id) at \(relativePath)")

        let newCount = await PhotoSessionManager.shared.addPhoto(path: relativePath, for: message.chat.id)
        // Обновляем время последней активности при загрузке фото
        await PhotoSessionManager.shared.setLastActivity(for: message.chat.id)
        let remaining = max(0, maximumPhotoCount - newCount)

        if newCount < minimumPhotoCount {
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: message.chat.id,
                text: "Фото \(newCount)/\(maximumPhotoCount) загружено. Мне нужно минимум \(minimumPhotoCount) снимков, добавь ещё \(minimumPhotoCount - newCount).",
                client: req.client
            )
        } else if newCount < maximumPhotoCount {
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: message.chat.id,
                text: "Фото \(newCount)/\(maximumPhotoCount) загружено. Этого уже достаточно, чтобы начать обучение. Если хочешь, добавь ещё \(remaining) или отправь команду /train, чтобы я запустила процесс.",
                client: req.client
            )
        } else if newCount == maximumPhotoCount {
            // Проверка подписки перед автоматическим запуском обучения (до модерации и создания dataset)
            let (allowed, channels) = await MonetizationService.checkAccess(
                botName: "Neurfotobot",
                userId: message.chat.id,
                logger: req.logger,
                env: req.application.environment,
                client: req.client
            )

            if !allowed {
                _ = try? await sendTelegramMessage(
                    token: token,
                    chatId: message.chat.id,
                    text: "Все \(maximumPhotoCount) фото получены и сохранены.",
                    client: req.client
                )
                try await sendSubscriptionRequiredMessage(
                    token: token,
                    chatId: message.chat.id,
                    channels: channels,
                    client: req.client
                )
                req.logger.info("Доступ для пользователя \(message.chat.id) ограничен спонсорской подпиской при автоматическом запуске обучения.")
                return
            }

            _ = try? await sendTelegramMessage(
                token: token,
                chatId: message.chat.id,
                text: "Все \(maximumPhotoCount) фото получены и сохранены. Проверяю их и запускаю обучение модели!",
                client: req.client
            )
            try await validatePhotos(chatId: message.chat.id, token: token, req: req)
        } else {
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: message.chat.id,
                text: "Я уже приняла \(maximumPhotoCount) фотографий. Дополнительные снимки можно будет использовать в следующей сессии.",
                client: req.client
            )
        }
    }

    private func handleTrainCommand(chatId: Int64, token: String, req: Request) async throws {
        // Обновляем время последней активности при попытке обучить модель
        await PhotoSessionManager.shared.setLastActivity(for: chatId)
        
        let trainingState = await PhotoSessionManager.shared.getTrainingState(for: chatId)
        switch trainingState {
        case .training:
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: "Я уже обучаю модель. Дождись окончания, пожалуйста.",
                client: req.client
            )
            return
        case .ready:
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: "Модель уже готова! Просто опиши образ, и я сгенерирую фото.",
                client: req.client
            )
            return
        case .failed:
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: "Прошлая попытка не удалась. Пришли, пожалуйста, новую подборку фото.",
                client: req.client
            )
            return
        case .idle:
            break
        }

        let photos = await PhotoSessionManager.shared.getPhotos(for: chatId)
        guard photos.count >= minimumPhotoCount else {
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: "Пока загружено только \(photos.count) фото. Нужно минимум \(minimumPhotoCount), чтобы начать обучение.",
                client: req.client
            )
            return
        }

        // Проверка подписки перед началом обучения (до модерации и создания dataset)
        let (allowed, channels) = await MonetizationService.checkAccess(
            botName: "Neurfotobot",
            userId: chatId,
            logger: req.logger,
            env: req.application.environment,
            client: req.client
        )

        if !allowed {
            try await sendSubscriptionRequiredMessage(
                token: token,
                chatId: chatId,
                channels: channels,
                client: req.client
            )
            req.logger.info("Доступ для пользователя \(chatId) ограничен спонсорской подпиской при попытке обучить модель.")
            return
        }

        // Проверка rate limit: не больше 1 обучения в час на пользователя
        let trainingAllowed = await NeurfotobotController.trainingRateLimiter.checkLimit(for: chatId)
        if !trainingAllowed {
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: "Обучение модели можно запускать не чаще одного раза в час. Подожди немного, пожалуйста.",
                client: req.client
            )
            req.logger.info("Rate limit: пользователь \(chatId) попытался запустить обучение слишком часто")
            return
        }
        
        _ = try? await sendTelegramMessage(
            token: token,
            chatId: chatId,
            text: "Проверяю фотографии и запускаю обучение!",
            client: req.client
        )
        try await validatePhotos(chatId: chatId, token: token, req: req)
    }

    private func fetchTelegramFileInfo(token: String, fileId: String, client: Client) async throws -> TelegramFileResponse {
        let url = URI(string: "https://api.telegram.org/bot\(token)/getFile?file_id=\(fileId)")
        let response = try await client.get(url)
        guard response.status == .ok, let body = response.body else {
            throw Abort(.badRequest, reason: "Failed to get file info from Telegram")
        }
        let data = body.getData(at: 0, length: body.readableBytes) ?? Data()
        let decoded = try JSONDecoder().decode(TelegramFileResponse.self, from: data)
        guard decoded.ok else {
            throw Abort(.badRequest, reason: "Telegram responded with ok=false for getFile")
        }
        return decoded
    }

    private func downloadTelegramFile(token: String, filePath: String, client: Client) async throws -> Data {
        let url = URI(string: "https://api.telegram.org/file/bot\(token)/\(filePath)")
        let response = try await client.get(url)
        guard response.status == .ok, let body = response.body else {
            throw Abort(.badRequest, reason: "Failed to download file from Telegram")
        }
        return body.getData(at: 0, length: body.readableBytes) ?? Data()
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        default: return "application/octet-stream"
        }
    }

    private func validatePhotos(chatId: Int64, token: String, req: Request) async throws {
        // На этом этапе считаем, что SafeSearch уже был выполнен при загрузке фото (или отключён флагом),
        // поэтому здесь просто запускаем обучение.
        _ = try? await sendTelegramMessage(
            token: token,
            chatId: chatId,
            text: "Отлично! Все фото прошли модерацию. Запускаю обучение модели и дам знать, когда можно будет описать образ.",
            client: req.client
        )

        let application = req.application
        let logger = req.logger
        Task.detached {
            await NeurfotobotPipelineService.shared.startTraining(chatId: chatId, botToken: token, application: application, logger: logger)
        }
    }

    private func handleModerationFail(chatId: Int64, token: String, photos: [PhotoSessionManager.PhotoRecord], req: Request) async throws {
        // Удаляем все локальные фото для этой сессии
        for photo in photos {
            do {
                let url = try NeurfotobotTempDirectory.fileURL(relativePath: photo.path)
                try FileManager.default.removeItem(at: url)
            } catch {
                req.logger.warning("Failed to delete local photo at \(photo.path) for chatId=\(chatId): \(error)")
            }
        }
        await PhotoSessionManager.shared.reset(for: chatId)
        _ = try? await sendTelegramMessage(
            token: token,
            chatId: chatId,
            text: "Не могу продолжить: некоторые фото не прошли модерацию SafeSearch. Попробуй другие снимки, пожалуйста.",
            client: req.client
        )
    }

    private func handlePrompt(text: String, message: NeurfotobotMessage, token: String, req: Request) async throws {
        let chatId = message.chat.id
        // Обновляем время последней активности при обработке промпта
        await PhotoSessionManager.shared.setLastActivity(for: chatId)
        
        let promptState = await PhotoSessionManager.shared.getPromptCollectionState(for: chatId)
        
        // Если мы собираем промпт пошагово, обрабатываем текущий шаг
        switch promptState {
        case .styleSelected:
            // Пользователь описал место (после нажатия кнопки "Опиши место действия")
            await PhotoSessionManager.shared.setUserLocation(text, for: chatId)
            await PhotoSessionManager.shared.setPromptCollectionState(.locationSelected, for: chatId)
            
            // Показываем кнопку для описания одежды
            let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
            var request = ClientRequest(method: .POST, url: url)
            let payload = SendInlineMessagePayload(
                chat_id: chatId,
                text: "Место сохранено! 📍\n\nГотов описать одежду?",
                reply_markup: ReplyMarkup(inline_keyboard: [
                    [InlineKeyboardButton(text: "👔 Опиши одежду и её цвет", callback_data: "ask_clothing")]
                ])
            )
            request.headers.add(name: .contentType, value: "application/json")
            request.body = try .init(data: JSONEncoder().encode(payload))
            _ = try await req.client.send(request)
            return
            
        case .locationSelected:
            // Пользователь описал одежду (после нажатия кнопки "Опиши одежду")
            await PhotoSessionManager.shared.setUserClothing(text, for: chatId)
            await PhotoSessionManager.shared.setPromptCollectionState(.clothingSelected, for: chatId)
            
            // Показываем кнопку для дополнительных деталей
            let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
            var request = ClientRequest(method: .POST, url: url)
            let payload = SendInlineMessagePayload(
                chat_id: chatId,
                text: "Одежда сохранена! 👔\n\nХочешь добавить дополнительные детали?",
                reply_markup: ReplyMarkup(inline_keyboard: [
                    [
                        InlineKeyboardButton(text: "➕ Дополнительный промпт", callback_data: "ask_additional"),
                        InlineKeyboardButton(text: "⏭ Пропустить", callback_data: "skip_additional")
                    ]
                ])
            )
            request.headers.add(name: .contentType, value: "application/json")
            request.body = try .init(data: JSONEncoder().encode(payload))
            _ = try await req.client.send(request)
            return
            
        case .clothingSelected:
            // Пользователь добавил дополнительные детали (после нажатия кнопки "Дополнительный промпт")
            // Это старый способ - просто текстовый ввод, теперь не используется, но оставляем для совместимости
            if text.lowercased().trimmingCharacters(in: .whitespaces) == "готово" || text.lowercased().trimmingCharacters(in: .whitespaces) == "готов" {
                // Пользователь написал "готово", пропускаем дополнительные детали
                await PhotoSessionManager.shared.setAdditionalDetails("", for: chatId)
            } else {
                await PhotoSessionManager.shared.setAdditionalDetails(text, for: chatId)
            }
            await PhotoSessionManager.shared.setPromptCollectionState(.readyToGenerate, for: chatId)
            
        case .selectingAdditionalParams:
            // Пользователь добавил текстовые дополнительные детали
            if text.lowercased().trimmingCharacters(in: .whitespaces) == "готово" || text.lowercased().trimmingCharacters(in: .whitespaces) == "готов" {
                // Пользователь написал "готово", пропускаем дополнительные детали
                await PhotoSessionManager.shared.setAdditionalDetails("", for: chatId)
            } else {
                await PhotoSessionManager.shared.setAdditionalDetails(text, for: chatId)
            }
            try await showPromptPreview(chatId: message.chat.id, token: token, req: req)
            return
            
        case .selectingAdditionalCategories:
            // Пользователь в процессе выбора категорий - игнорируем текстовый ввод
            return
            
        case .genderSelected:
            // Пол выбран (старый flow, теперь не используется, но оставляем для совместимости)
            // Переходим к описанию места
            await PhotoSessionManager.shared.setUserLocation(text, for: chatId)
            await PhotoSessionManager.shared.setPromptCollectionState(.locationSelected, for: chatId)
            
            // Показываем кнопку для описания одежды
            let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
            var request = ClientRequest(method: .POST, url: url)
            let payload = SendInlineMessagePayload(
                chat_id: chatId,
                text: "Место сохранено! 📍\n\nГотов описать одежду?",
                reply_markup: ReplyMarkup(inline_keyboard: [
                    [InlineKeyboardButton(text: "👔 Опиши одежду и её цвет", callback_data: "ask_clothing")]
                ])
            )
            request.headers.add(name: .contentType, value: "application/json")
            request.body = try .init(data: JSONEncoder().encode(payload))
            _ = try await req.client.send(request)
            return
            
        case .readyToGenerate:
            // Промпт уже готов - игнорируем текстовый ввод
            return
            
        case .editingLocation:
            // Пользователь редактирует место
            await PhotoSessionManager.shared.setUserLocation(text, for: chatId)
            await PhotoSessionManager.shared.setPromptCollectionState(.readyToGenerate, for: chatId)
            // Показываем обновленное превью
            try await showPromptPreview(chatId: message.chat.id, token: token, req: req)
            return
            
        case .editingClothing:
            // Пользователь редактирует одежду
            await PhotoSessionManager.shared.setUserClothing(text, for: chatId)
            await PhotoSessionManager.shared.setPromptCollectionState(.readyToGenerate, for: chatId)
            // Показываем обновленное превью
            try await showPromptPreview(chatId: message.chat.id, token: token, req: req)
            return
            
        case .editingDetails:
            // Пользователь редактирует дополнительные детали
            if text.lowercased().trimmingCharacters(in: .whitespaces) == "готово" || text.lowercased().trimmingCharacters(in: .whitespaces) == "готов" {
                // Пользователь написал "готово", пропускаем дополнительные детали
                await PhotoSessionManager.shared.setAdditionalDetails("", for: chatId)
            } else {
                await PhotoSessionManager.shared.setAdditionalDetails(text, for: chatId)
            }
            await PhotoSessionManager.shared.setPromptCollectionState(.readyToGenerate, for: chatId)
            // Показываем обновленное превью
            try await showPromptPreview(chatId: message.chat.id, token: token, req: req)
            return
            
        case .idle:
            // Временно автоматически выбираем "Обычное фото" вместо показа меню
            await PhotoSessionManager.shared.setStyle("photo", for: chatId)
            await PhotoSessionManager.shared.setPromptCollectionState(.styleSelected, for: chatId)
            await PhotoSessionManager.shared.clearPromptCollectionData(for: chatId)
            
            // УБРАНО: Выбор пола, так как он не используется в промпте
            // Сразу переходим к описанию места
            let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
            var request = ClientRequest(method: .POST, url: url)
            let payload = SendInlineMessagePayload(
                chat_id: chatId,
                text: "Готов описать место действия?",
                reply_markup: ReplyMarkup(inline_keyboard: [
                    [InlineKeyboardButton(text: "📍 Опиши место действия", callback_data: "ask_location")]
                ])
            )
            request.headers.add(name: .contentType, value: "application/json")
            request.body = try .init(data: JSONEncoder().encode(payload))
            _ = try await req.client.send(request)
            return
            
            // ЗАКОММЕНТИРОВАНО: Меню выбора стиля
            // let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
            // var request = ClientRequest(method: .POST, url: url)
            // let payload = SendInlineMessagePayload(
            //     chat_id: chatId,
            //     text: "Выбери стиль генерации, затем опиши образ. Например: \"я в чёрном пальто в осеннем Париже\"",
            //     reply_markup: ReplyMarkup(inline_keyboard: [
            //         [InlineKeyboardButton(text: "🎬 Кинематографично", callback_data: "style_cinematic")],
            //         [InlineKeyboardButton(text: "🎨 Аниме", callback_data: "style_anime")],
            //         [InlineKeyboardButton(text: "🤖 Киберпанк", callback_data: "style_cyberpunk")],
            //         [InlineKeyboardButton(text: "📸 Обычное фото", callback_data: "style_photo")]
            //     ])
            // )
            // request.headers.add(name: .contentType, value: "application/json")
            // request.body = try .init(data: JSONEncoder().encode(payload))
            // _ = try await req.client.send(request)
            // return
        }
    }
    
    private func finalizeAndGeneratePrompt(chatId: Int64, token: String, req: Request) async throws {
        // Проверяем наличие модели
        var modelVersion = await PhotoSessionManager.shared.getModelVersion(for: chatId)
        
        // Если модели нет в памяти, проверяем базу данных
        if modelVersion == nil {
            do {
                if let userModel = try await UserModel.query(on: req.db)
                    .filter(\.$chatId == chatId)
                    .first() {
                    modelVersion = userModel.modelVersion
                    await PhotoSessionManager.shared.setModelVersion(userModel.modelVersion, for: chatId)
                    await PhotoSessionManager.shared.setTriggerWord(userModel.triggerWord, for: chatId)
                    await PhotoSessionManager.shared.setTrainingState(.ready, for: chatId)
                    req.logger.info("Restored model from database for chatId=\(chatId) in finalizeAndGeneratePrompt")
                }
            } catch {
                req.logger.warning("Failed to check database for model version in finalizeAndGeneratePrompt: \(error)")
            }
        }
        
        // Если модели нет даже после проверки - сообщаем пользователю
        guard modelVersion != nil else {
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: "Модель не найдена. Используй команду /model для проверки статуса или начни обучение заново.",
                client: req.client
            )
            return
        }
        
        // Собираем финальный промпт из всех частей
        // УБРАНО: gender не используется в промпте
        let location = await PhotoSessionManager.shared.getUserLocation(for: chatId) ?? ""
        let clothing = await PhotoSessionManager.shared.getUserClothing(for: chatId) ?? ""
        let additionalDetails = await PhotoSessionManager.shared.getAdditionalDetails(for: chatId) ?? ""
        
        // Собираем дополнительные параметры
        var additionalParams: [String] = []
        if let angle = await PhotoSessionManager.shared.getCameraAngle(for: chatId) {
            let angleNames: [String: String] = [
                "front": "спереди",
                "side": "сбоку",
                "back": "сзади",
                "top": "сверху",
                "low": "снизу",
                "three_quarter": "3/4"
            ]
            additionalParams.append(angleNames[angle] ?? angle)
        }
        if let size = await PhotoSessionManager.shared.getShotSize(for: chatId) {
            let sizeNames: [String: String] = [
                "close_up": "крупный план",
                "medium": "средний план",
                "full_body": "общий план",
                "portrait": "портрет"
            ]
            additionalParams.append(sizeNames[size] ?? size)
        }
        if let lighting = await PhotoSessionManager.shared.getLighting(for: chatId) {
            let lightingNames: [String: String] = [
                "natural": "естественное освещение",
                "golden_hour": "золотой час",
                "blue_hour": "синий час",
                "studio": "студийное освещение",
                "backlight": "контровое освещение",
                "soft": "мягкое освещение"
            ]
            additionalParams.append(lightingNames[lighting] ?? lighting)
        }
        if let pose = await PhotoSessionManager.shared.getPose(for: chatId) {
            let poseNames: [String: String] = [
                "standing": "стоя",
                "sitting": "сидя",
                "lying": "лежа",
                "motion": "в движении"
            ]
            additionalParams.append(poseNames[pose] ?? pose)
        }
        if let expression = await PhotoSessionManager.shared.getExpression(for: chatId) {
            let expressionNames: [String: String] = [
                "smiling": "улыбка",
                "serious": "серьёзное",
                "looking_at_camera": "взгляд в камеру",
                "looking_away": "взгляд в сторону"
            ]
            additionalParams.append(expressionNames[expression] ?? expression)
        }
        if let focus = await PhotoSessionManager.shared.getFocus(for: chatId) {
            let focusNames: [String: String] = [
                "sharp": "резкий фокус",
                "bokeh": "размытый фон"
            ]
            additionalParams.append(focusNames[focus] ?? focus)
        }
        
        // Формируем промпт: место + одежда + дополнительные параметры + текстовые детали
        var promptParts: [String] = []
        if !location.isEmpty {
            promptParts.append("в \(location)")
        }
        if !clothing.isEmpty {
            promptParts.append("в \(clothing)")
        }
        if !additionalParams.isEmpty {
            promptParts.append(additionalParams.joined(separator: ", "))
        }
        if !additionalDetails.isEmpty {
            promptParts.append(additionalDetails)
        }
        
        let finalPrompt = promptParts.joined(separator: ", ")
        
        // Проверяем модерацию текста (если не отключена)
        let promptModerationDisabled = Environment.get("DISABLE_PROMPT_MODERATION")?.lowercased() == "true"
        if !promptModerationDisabled {
            do {
                let moderation = try OpenAIModerationClient(request: req)
                let analysis = try await moderation.analyze(text: finalPrompt)
                guard !analysis.flagged else {
                    _ = try? await sendTelegramMessage(
                        token: token,
                        chatId: chatId,
                        text: "Текст содержит запрещённые темы (\(analysis.violations.joined(separator: ", "))). Попробуй описать образ по-другому.",
                        client: req.client
                    )
                    await PhotoSessionManager.shared.clearPromptCollectionData(for: chatId)
                    return
                }
            } catch {
                req.logger.warning("OpenAI moderation failed for chatId=\(chatId): \(error). Proceeding without moderation.")
            }
        } else {
            req.logger.warning("Prompt moderation is disabled via DISABLE_PROMPT_MODERATION env flag; skipping moderation for chatId=\(chatId)")
        }
        
        // Используем уже переведённый промпт (если есть) или переводим заново (если перевод не отключен)
        let translationDisabled = Environment.get("DISABLE_TRANSLATION")?.lowercased() == "true"
        let translatedPrompt: String
        if translationDisabled {
            // Перевод отключен - используем русский промпт
            translatedPrompt = finalPrompt
            req.logger.info("Translation disabled; using Russian prompt for chatId=\(chatId): '\(translatedPrompt)'")
        } else if let savedTranslated = await PhotoSessionManager.shared.getTranslatedPrompt(for: chatId), !savedTranslated.isEmpty {
            translatedPrompt = savedTranslated
            req.logger.info("Using saved translated prompt for chatId=\(chatId): '\(translatedPrompt)'")
        } else {
            // Если переведённого промпта нет, переводим сейчас
            do {
                let translator = try YandexTranslationClient(request: req)
                translatedPrompt = try await translator.translateToEnglish(finalPrompt)
                await PhotoSessionManager.shared.setTranslatedPrompt(translatedPrompt, for: chatId)
                req.logger.info("Translated prompt for chatId=\(chatId): '\(finalPrompt)' -> '\(translatedPrompt)'")
            } catch {
                req.logger.warning("Translation failed for chatId=\(chatId): \(error). Using original Russian prompt.")
                translatedPrompt = finalPrompt
            }
        }
        
        // Проверка rate limit: не больше 2 генераций в минуту на пользователя
        let generationAllowed = await NeurfotobotController.generationRateLimiter.checkLimit(for: chatId)
        if !generationAllowed {
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: "Генерацию можно запускать не чаще двух раз в минуту. Подожди немного, пожалуйста.",
                client: req.client
            )
            req.logger.info("Rate limit: пользователь \(chatId) попытался сгенерировать фото слишком часто (минутный лимит)")
            await PhotoSessionManager.shared.clearPromptCollectionData(for: chatId)
            return
        }
        
        // Проверка дневного лимита: не больше 50 генераций в сутки на пользователя
        let dailyAllowed = await NeurfotobotController.generationDailyLimiter.checkLimit(for: chatId)
        if !dailyAllowed {
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: "Дневной лимит генераций исчерпан (максимум 50 фото в сутки). Попробуй завтра.",
                client: req.client
            )
            req.logger.info("Daily limit: пользователь \(chatId) исчерпал дневной лимит генераций")
            await PhotoSessionManager.shared.clearPromptCollectionData(for: chatId)
            return
        }
        
        // Сохраняем промпт
        await PhotoSessionManager.shared.setPrompt(translatedPrompt, for: chatId)
        
        // Очищаем состояние сбора промпта
        await PhotoSessionManager.shared.clearPromptCollectionData(for: chatId)
        
        let application = req.application
        let logger = req.logger
        Task.detached {
            // УБРАНО: userGender, так как пол не используется в промпте (модель уже обучена на конкретном лице)
            await NeurfotobotPipelineService.shared.generateImages(
                chatId: chatId,
                prompt: translatedPrompt,
                userGender: nil,
                botToken: token,
                application: application,
                logger: logger
            )
        }
    }

    private func handleModelCommand(chatId: Int64, token: String, req: Request) async throws {
        var modelVersion = await PhotoSessionManager.shared.getModelVersion(for: chatId)
        
        // Если модели нет в памяти, проверяем базу данных
        if modelVersion == nil {
            do {
                if let userModel = try await UserModel.query(on: req.db)
                    .filter(\.$chatId == chatId)
                    .first() {
                    modelVersion = userModel.modelVersion
                    await PhotoSessionManager.shared.setModelVersion(userModel.modelVersion, for: chatId)
                    await PhotoSessionManager.shared.setTriggerWord(userModel.triggerWord, for: chatId)
                    await PhotoSessionManager.shared.setTrainingState(.ready, for: chatId)
                    req.logger.info("Restored model from database for chatId=\(chatId) in handleModelCommand")
                }
            } catch {
                req.logger.warning("Failed to check database for model version in handleModelCommand: \(error)")
            }
        }
        
        if modelVersion != nil {
            let message = "Твоя модель готова к работе! 🎨\n\nМожешь сгенерировать изображение или удалить модель."
            let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
            var request = ClientRequest(method: .POST, url: url)
            let payload = SendInlineMessagePayload(
                chat_id: chatId,
                text: message,
                reply_markup: ReplyMarkup(inline_keyboard: [
                    [InlineKeyboardButton(text: "📝 Составить промпт", callback_data: "start_generate")],
                    [InlineKeyboardButton(text: "🗑 Удалить модель", callback_data: "delete_model")]
                ])
            )
            request.headers.add(name: .contentType, value: "application/json")
            request.body = try .init(data: JSONEncoder().encode(payload))
            _ = try await req.client.send(request)
        } else {
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: "Пока что персональная модель не создана. Пришли хотя бы \(minimumPhotoCount) фото (до \(maximumPhotoCount)), чтобы мы могли её обучить.",
                client: req.client
            )
        }
    }

    private func handleGenerateCommand(chatId: Int64, token: String, req: Request) async throws {
        var modelVersion = await PhotoSessionManager.shared.getModelVersion(for: chatId)
        
        // Если модели нет в памяти, проверяем базу данных
        if modelVersion == nil {
            do {
                if let userModel = try await UserModel.query(on: req.db)
                    .filter(\.$chatId == chatId)
                    .first() {
                    modelVersion = userModel.modelVersion
                    await PhotoSessionManager.shared.setModelVersion(userModel.modelVersion, for: chatId)
                    await PhotoSessionManager.shared.setTriggerWord(userModel.triggerWord, for: chatId)
                    await PhotoSessionManager.shared.setTrainingState(.ready, for: chatId)
                    req.logger.info("Restored model from database for chatId=\(chatId) in handleGenerateCommand")
                }
            } catch {
                req.logger.warning("Failed to check database for model version in handleGenerateCommand: \(error)")
            }
        }
        
        guard modelVersion != nil else {
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: "У тебя пока нет обученной модели. Сначала пришли \(minimumPhotoCount)-\(maximumPhotoCount) фото и обучи модель командой /train.",
                client: req.client
            )
            return
        }

        let trainingState = await PhotoSessionManager.shared.getTrainingState(for: chatId)
        guard trainingState == .ready else {
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: "Модель ещё не готова. Дождись завершения обучения.",
                client: req.client
            )
            return
        }

        // Временно автоматически выбираем "Обычное фото" вместо показа меню
        await PhotoSessionManager.shared.setStyle("photo", for: chatId)
        await PhotoSessionManager.shared.setPromptCollectionState(.styleSelected, for: chatId)
        await PhotoSessionManager.shared.clearPromptCollectionData(for: chatId)
        
        // УБРАНО: Выбор пола, так как он не используется в промпте (модель уже обучена на конкретном лице)
        // Сразу переходим к описанию места
        let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
        var request = ClientRequest(method: .POST, url: url)
        let payload = SendInlineMessagePayload(
            chat_id: chatId,
            text: "Готов описать место действия?",
            reply_markup: ReplyMarkup(inline_keyboard: [
                [InlineKeyboardButton(text: "📍 Опиши место действия", callback_data: "ask_location")]
            ])
        )
        request.headers.add(name: .contentType, value: "application/json")
        request.body = try .init(data: JSONEncoder().encode(payload))
        _ = try await req.client.send(request)
        
        // ЗАКОММЕНТИРОВАНО: Меню выбора стиля
        // let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
        // var request = ClientRequest(method: .POST, url: url)
        // let payload = SendInlineMessagePayload(
        //     chat_id: chatId,
        //     text: "Выбери стиль генерации, затем опиши образ. Например: \"я в чёрном пальто в осеннем Париже\"",
        //     reply_markup: ReplyMarkup(inline_keyboard: [
        //         [InlineKeyboardButton(text: "🎬 Кинематографично", callback_data: "style_cinematic")],
        //         [InlineKeyboardButton(text: "🎨 Аниме", callback_data: "style_anime")],
        //         [InlineKeyboardButton(text: "🤖 Киберпанк", callback_data: "style_cyberpunk")],
        //         [InlineKeyboardButton(text: "📸 Обычное фото", callback_data: "style_photo")]
        //     ])
        // )
        // request.headers.add(name: .contentType, value: "application/json")
        // request.body = try .init(data: JSONEncoder().encode(payload))
        // _ = try await req.client.send(request)
    }

    private func handleCallback(_ callback: NeurfotobotCallbackQuery, token: String, req: Request) async throws {
        guard let data = callback.data else {
            try await answerCallbackQuery(token: token, callbackId: callback.id, text: nil, req: req)
            return
        }

        switch data {
        case "delete_model":
            let chatId: Int64
            if let messageChatId = callback.message?.chat.id {
                chatId = messageChatId
            } else {
                chatId = callback.from.id
            }
            try await answerCallbackQuery(token: token, callbackId: callback.id, text: "Удаляю модель...", req: req)
            let application = req.application
            let logger = req.logger
            Task.detached {
                await NeurfotobotPipelineService.shared.deleteModel(chatId: chatId, botToken: token, application: application, logger: logger)
            }
        case "show_model_info":
            let chatId: Int64
            if let messageChatId = callback.message?.chat.id {
                chatId = messageChatId
            } else {
                chatId = callback.from.id
            }
            try await handleModelCommand(chatId: chatId, token: token, req: req)
            try await answerCallbackQuery(token: token, callbackId: callback.id, text: nil, req: req)
        case "train_from_start":
            let chatId: Int64
            if let messageChatId = callback.message?.chat.id {
                chatId = messageChatId
            } else {
                chatId = callback.from.id
            }
            try await answerCallbackQuery(token: token, callbackId: callback.id, text: "Запускаю обучение...", req: req)
            try await handleTrainCommand(chatId: chatId, token: token, req: req)
        case "add_photos", "start_upload":
            let chatId: Int64
            if let messageChatId = callback.message?.chat.id {
                chatId = messageChatId
            } else {
                chatId = callback.from.id
            }
            try await answerCallbackQuery(token: token, callbackId: callback.id, text: nil, req: req)
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: "Отправь мне \(minimumPhotoCount)-\(maximumPhotoCount) своих фотографий, где хорошо видно лицо. После загрузки используй команду /train для обучения модели.",
                client: req.client
            )
        case "start_generate":
            let chatId: Int64
            if let messageChatId = callback.message?.chat.id {
                chatId = messageChatId
            } else {
                chatId = callback.from.id
            }
            
            var modelVersion = await PhotoSessionManager.shared.getModelVersion(for: chatId)
            
            // Если модели нет в памяти, проверяем базу данных
            if modelVersion == nil {
                do {
                    if let userModel = try await UserModel.query(on: req.db)
                        .filter(\.$chatId == chatId)
                        .first() {
                        modelVersion = userModel.modelVersion
                        await PhotoSessionManager.shared.setModelVersion(userModel.modelVersion, for: chatId)
                        await PhotoSessionManager.shared.setTriggerWord(userModel.triggerWord, for: chatId)
                        await PhotoSessionManager.shared.setTrainingState(.ready, for: chatId)
                        req.logger.info("Restored model from database for chatId=\(chatId) in start_generate")
                    }
                } catch {
                    req.logger.warning("Failed to check database for model version in start_generate: \(error)")
                }
            }
            
            guard modelVersion != nil else {
                try await answerCallbackQuery(token: token, callbackId: callback.id, text: "Модель не найдена", req: req)
                _ = try? await sendTelegramMessage(
                    token: token,
                    chatId: chatId,
                    text: "У тебя пока нет обученной модели. Сначала пришли \(minimumPhotoCount)-\(maximumPhotoCount) фото и обучи модель командой /train.",
                    client: req.client
                )
                return
            }
            
            let trainingState = await PhotoSessionManager.shared.getTrainingState(for: chatId)
            guard trainingState == .ready else {
                try await answerCallbackQuery(token: token, callbackId: callback.id, text: "Модель ещё не готова", req: req)
                return
            }
            
            try await answerCallbackQuery(token: token, callbackId: callback.id, text: nil, req: req)
            try await handleGenerateCommand(chatId: chatId, token: token, req: req)
            
        case "finalize_generate":
            let chatId: Int64
            if let messageChatId = callback.message?.chat.id {
                chatId = messageChatId
            } else {
                chatId = callback.from.id
            }
            
            // Проверка подписки перед генерацией
            let (allowed, channels) = await MonetizationService.checkAccess(
                botName: "Neurfotobot",
                userId: chatId,
                logger: req.logger,
                env: req.application.environment,
                client: req.client
            )
            
            if !allowed {
                try await answerCallbackQuery(token: token, callbackId: callback.id, text: "Требуется подписка на спонсорские каналы", req: req)
                try await sendSubscriptionRequiredMessage(
                    token: token,
                    chatId: chatId,
                    channels: channels,
                    client: req.client
                )
                return
            }
            
            try await answerCallbackQuery(token: token, callbackId: callback.id, text: "Запускаю генерацию...", req: req)
            try await finalizeAndGeneratePrompt(chatId: chatId, token: token, req: req)
            
        // ЗАКОММЕНТИРОВАНО: Обработчики выбора стиля (временно отключены, автоматически выбирается "Обычное фото")
        // case "style_cinematic", "style_anime", "style_cyberpunk", "style_photo":
        case "style_photo": // Оставляем только для совместимости, но не используется
            let chatId: Int64
            if let messageChatId = callback.message?.chat.id {
                chatId = messageChatId
            } else {
                chatId = callback.from.id
            }
            
            let style = String(data.dropFirst(6)) // Убираем "style_" префикс
            await PhotoSessionManager.shared.setStyle(style, for: chatId)
            await PhotoSessionManager.shared.setPromptCollectionState(.styleSelected, for: chatId)
            await PhotoSessionManager.shared.clearPromptCollectionData(for: chatId) // Очищаем предыдущие данные
            
            let styleNames: [String: String] = [
                "cinematic": "🎬 Кинематографично",
                "anime": "🎨 Аниме",
                "cyberpunk": "🤖 Киберпанк",
                "photo": "📸 Обычное фото"
            ]
            let styleName = styleNames[style] ?? style
            
            try await answerCallbackQuery(token: token, callbackId: callback.id, text: "Выбран стиль: \(styleName)", req: req)
            
            // Спрашиваем пол
            let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
            var request = ClientRequest(method: .POST, url: url)
            let payload = SendInlineMessagePayload(
                chat_id: chatId,
                text: "Стиль \(styleName) выбран! 🎨\n\nВыбери пол:",
                reply_markup: ReplyMarkup(inline_keyboard: [
                    [InlineKeyboardButton(text: "👨 Мужской", callback_data: "gender_male")],
                    [InlineKeyboardButton(text: "👩 Женский", callback_data: "gender_female")]
                ])
            )
            request.headers.add(name: .contentType, value: "application/json")
            request.body = try .init(data: JSONEncoder().encode(payload))
            _ = try await req.client.send(request)
            
        case "gender_male", "gender_female":
            let chatId: Int64
            if let messageChatId = callback.message?.chat.id {
                chatId = messageChatId
            } else {
                chatId = callback.from.id
            }
            
            let gender = String(data.dropFirst(7)) // Убираем "gender_" префикс
            await PhotoSessionManager.shared.setUserGender(gender, for: chatId)
            await PhotoSessionManager.shared.setPromptCollectionState(.genderSelected, for: chatId)
            
            let genderName = gender == "male" ? "👨 Мужской" : "👩 Женский"
            try await answerCallbackQuery(token: token, callbackId: callback.id, text: "Выбран пол: \(genderName)", req: req)
            
            // Показываем кнопку для описания места
            let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
            var request = ClientRequest(method: .POST, url: url)
            let payload = SendInlineMessagePayload(
                chat_id: chatId,
                text: "Пол выбран! 🎯\n\nГотов описать место действия?",
                reply_markup: ReplyMarkup(inline_keyboard: [
                    [InlineKeyboardButton(text: "📍 Опиши место действия", callback_data: "ask_location")]
                ])
            )
            request.headers.add(name: .contentType, value: "application/json")
            request.body = try .init(data: JSONEncoder().encode(payload))
            _ = try await req.client.send(request)
            
        case "ask_location":
            let chatId: Int64
            if let messageChatId = callback.message?.chat.id {
                chatId = messageChatId
            } else {
                chatId = callback.from.id
            }
            
            try await answerCallbackQuery(token: token, callbackId: callback.id, text: nil, req: req)
            await PhotoSessionManager.shared.setPromptCollectionState(.styleSelected, for: chatId)
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: "Опиши место, где ты хочешь себя увидеть. Например: \"осенний Париж\", \"пляж на Мальдивах\", \"космическая станция\"",
                client: req.client
            )
            
        case "ask_clothing":
            let chatId: Int64
            if let messageChatId = callback.message?.chat.id {
                chatId = messageChatId
            } else {
                chatId = callback.from.id
            }
            
            try await answerCallbackQuery(token: token, callbackId: callback.id, text: nil, req: req)
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: "Опиши одежду и её цвет. Например: \"чёрное пальто\", \"белые джинсы и синяя футболка\", \"элегантное платье\"",
                client: req.client
            )
            
        case "ask_additional":
            let chatId: Int64
            if let messageChatId = callback.message?.chat.id {
                chatId = messageChatId
            } else {
                chatId = callback.from.id
            }
            
            try await answerCallbackQuery(token: token, callbackId: callback.id, text: nil, req: req)
            await PhotoSessionManager.shared.setPromptCollectionState(.selectingAdditionalParams, for: chatId)
            
            // Показываем текстовое сообщение с подсказками вместо кнопок
            let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
            var request = ClientRequest(method: .POST, url: url)
            let hintText = """
✨ Дополнительные детали

Ты можешь описать любые детали, которые помогут создать идеальное изображение:

📷 **Угол камеры:** спереди, сбоку, сзади, сверху, снизу, 3/4
📐 **Крупность плана:** крупный план, средний план, общий план, портрет
💡 **Освещение:** естественное, золотой час, синий час, студийное, контровое, мягкое
🧍 **Поза:** стоя, сидя, лежа, в движении
😊 **Выражение лица:** улыбка, серьёзное, взгляд в камеру, взгляд в сторону
🎯 **Фокус:** резкий фокус, размытый фон

Или просто опиши любые другие детали, которые хочешь видеть на изображении.

Напиши всё, что хочешь добавить, или отправь "готово" чтобы пропустить.
"""
            let payload = SendInlineMessagePayload(
                chat_id: chatId,
                text: hintText,
                reply_markup: ReplyMarkup(inline_keyboard: [
                    [InlineKeyboardButton(text: "⏭ Пропустить", callback_data: "skip_additional")]
                ])
            )
            request.headers.add(name: .contentType, value: "application/json")
            request.body = try .init(data: JSONEncoder().encode(payload))
            _ = try await req.client.send(request)

        case "add_category_camera_angle", "add_category_shot_size", "add_category_lighting", "add_category_pose", "add_category_expression", "add_category_focus":
            let chatId: Int64
            if let messageChatId = callback.message?.chat.id {
                chatId = messageChatId
            } else {
                chatId = callback.from.id
            }
            
            let category = String(data.dropFirst(12)) // Убираем "add_category_" префикс
            
            // Добавляем категорию в выбранные (если ещё не добавлена)
            var selectedCategories = await PhotoSessionManager.shared.getSelectedAdditionalCategories(for: chatId)
            if !selectedCategories.contains(category) {
                selectedCategories.insert(category)
                await PhotoSessionManager.shared.setSelectedAdditionalCategories(selectedCategories, for: chatId)
            }
            
            try await answerCallbackQuery(token: token, callbackId: callback.id, text: nil, req: req)
            await PhotoSessionManager.shared.setPromptCollectionState(.selectingAdditionalParams, for: chatId)
            
            // Сразу показываем параметры для выбранной категории
            try await showCategoryParams(chatId: chatId, token: token, category: category, req: req)
            
        case "finish_additional_categories":
            let chatId: Int64
            if let messageChatId = callback.message?.chat.id {
                chatId = messageChatId
            } else {
                chatId = callback.from.id
            }
            
            try await answerCallbackQuery(token: token, callbackId: callback.id, text: nil, req: req)
            
            // Показываем опцию добавить текст или завершить
            try await showFinalAdditionalStep(chatId: chatId, token: token, req: req)
            
        case "back_to_categories":
            let chatId: Int64
            if let messageChatId = callback.message?.chat.id {
                chatId = messageChatId
            } else {
                chatId = callback.from.id
            }
            
            try await answerCallbackQuery(token: token, callbackId: callback.id, text: nil, req: req)
            await PhotoSessionManager.shared.setPromptCollectionState(.selectingAdditionalCategories, for: chatId)
            
            // Показываем главное меню с категориями
            let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
            var request = ClientRequest(method: .POST, url: url)
            let payload = SendInlineMessagePayload(
                chat_id: chatId,
                text: "📸 Дополнительные параметры\n\nВыбери, что хочешь уточнить:",
                reply_markup: ReplyMarkup(inline_keyboard: [
                    [InlineKeyboardButton(text: "📷 Угол камеры", callback_data: "add_category_camera_angle")],
                    [InlineKeyboardButton(text: "📐 Крупность плана", callback_data: "add_category_shot_size")],
                    [InlineKeyboardButton(text: "💡 Освещение", callback_data: "add_category_lighting")],
                    [InlineKeyboardButton(text: "🧍 Поза", callback_data: "add_category_pose")],
                    [InlineKeyboardButton(text: "😊 Выражение лица", callback_data: "add_category_expression")],
                    [InlineKeyboardButton(text: "🎯 Фокус", callback_data: "add_category_focus")],
                    [InlineKeyboardButton(text: "✅ Готово", callback_data: "finish_additional_categories"), InlineKeyboardButton(text: "⏭ Пропустить всё", callback_data: "skip_additional")]
                ])
            )
            request.headers.add(name: .contentType, value: "application/json")
            request.body = try .init(data: JSONEncoder().encode(payload))
            _ = try await req.client.send(request)
            
        case let data where data.hasPrefix("select_param_"):
            let chatId: Int64
            if let messageChatId = callback.message?.chat.id {
                chatId = messageChatId
            } else {
                chatId = callback.from.id
            }
            
            // Формат: "select_param_camera_front" -> type="camera", value="front"
            // Или: "select_param_shot_size_close_up" -> type="shot_size", value="close_up"
            let remaining = String(data.dropFirst(13)) // Убираем "select_param_"
            let parts = remaining.split(separator: "_", maxSplits: 1)
            guard parts.count == 2 else {
                try await answerCallbackQuery(token: token, callbackId: callback.id, text: "Ошибка формата", req: req)
                return
            }
            
            let paramType = String(parts[0])
            let paramValue = String(parts[1])
            
            // Сохраняем выбранный параметр
            switch paramType {
            case "camera":
                await PhotoSessionManager.shared.setCameraAngle(paramValue, for: chatId)
            case "shot":
                await PhotoSessionManager.shared.setShotSize(paramValue, for: chatId)
            case "lighting":
                await PhotoSessionManager.shared.setLighting(paramValue, for: chatId)
            case "pose":
                await PhotoSessionManager.shared.setPose(paramValue, for: chatId)
            case "expression":
                await PhotoSessionManager.shared.setExpression(paramValue, for: chatId)
            case "focus":
                await PhotoSessionManager.shared.setFocus(paramValue, for: chatId)
            default:
                break
            }
            
            try await answerCallbackQuery(token: token, callbackId: callback.id, text: "Параметр выбран", req: req)
            
            // После выбора параметра возвращаемся к меню категорий
            await PhotoSessionManager.shared.setPromptCollectionState(.selectingAdditionalCategories, for: chatId)
            
            // Показываем главное меню с категориями (с отметками выбранных параметров)
            let _ = await PhotoSessionManager.shared.getSelectedAdditionalCategories(for: chatId)
            let categoryNames: [String: String] = [
                "camera_angle": "📷 Угол камеры",
                "shot_size": "📐 Крупность плана",
                "lighting": "💡 Освещение",
                "pose": "🧍 Поза",
                "expression": "😊 Выражение лица",
                "focus": "🎯 Фокус"
            ]
            
            var keyboard: [[InlineKeyboardButton]] = []
            for (cat, name) in categoryNames {
                let hasParam = await hasParamSelected(chatId: chatId, category: cat)
                let buttonText = hasParam ? "✅ \(name)" : name
                keyboard.append([InlineKeyboardButton(text: buttonText, callback_data: "add_category_\(cat)")])
            }
            keyboard.append([InlineKeyboardButton(text: "✅ Готово", callback_data: "finish_additional_categories"), InlineKeyboardButton(text: "⏭ Пропустить всё", callback_data: "skip_additional")])
            
            let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
            var request = ClientRequest(method: .POST, url: url)
            let payload = SendInlineMessagePayload(
                chat_id: chatId,
                text: "📸 Дополнительные параметры\n\nВыбери, что хочешь уточнить:",
                reply_markup: ReplyMarkup(inline_keyboard: keyboard)
            )
            request.headers.add(name: .contentType, value: "application/json")
            request.body = try .init(data: JSONEncoder().encode(payload))
            _ = try await req.client.send(request)
            
        case "add_text_additional":
            let chatId: Int64
            if let messageChatId = callback.message?.chat.id {
                chatId = messageChatId
            } else {
                chatId = callback.from.id
            }
            
            try await answerCallbackQuery(token: token, callbackId: callback.id, text: nil, req: req)
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: "Опиши дополнительные детали текстом. Например: \"с книгой в руках\", \"на фоне гор\"",
                client: req.client
            )
            
        case "finish_additional_without_text":
            let chatId: Int64
            if let messageChatId = callback.message?.chat.id {
                chatId = messageChatId
            } else {
                chatId = callback.from.id
            }
            
            try await answerCallbackQuery(token: token, callbackId: callback.id, text: nil, req: req)
            await PhotoSessionManager.shared.setAdditionalDetails("", for: chatId)
            try await showPromptPreview(chatId: chatId, token: token, req: req)

        case "skip_additional":
            let chatId: Int64
            if let messageChatId = callback.message?.chat.id {
                chatId = messageChatId
            } else {
                chatId = callback.from.id
            }
            
            try await answerCallbackQuery(token: token, callbackId: callback.id, text: "Пропускаю дополнительные детали", req: req)
            
            // Сбрасываем дополнительные детали и помечаем состояние как готовое к генерации
            await PhotoSessionManager.shared.setAdditionalDetails("", for: chatId)
            await PhotoSessionManager.shared.setPromptCollectionState(.readyToGenerate, for: chatId)
            
            // Собираем составной промпт из уже сохранённых частей (место + одежда)
            let location = await PhotoSessionManager.shared.getUserLocation(for: chatId) ?? ""
            let clothing = await PhotoSessionManager.shared.getUserClothing(for: chatId) ?? ""
            
            var promptParts: [String] = []
            if !location.isEmpty {
                promptParts.append("в \(location)")
            }
            if !clothing.isEmpty {
                promptParts.append("в \(clothing)")
            }
            let russianPrompt = promptParts.joined(separator: ", ")
            
            // Переводим на английский (или используем русский, если перевод отключён)
            let translationDisabled = Environment.get("DISABLE_TRANSLATION")?.lowercased() == "true"
            let englishPrompt: String
            if !translationDisabled {
                do {
                    let translator = try YandexTranslationClient(request: req)
                    englishPrompt = try await translator.translateToEnglish(russianPrompt)
                    await PhotoSessionManager.shared.setTranslatedPrompt(englishPrompt, for: chatId)
                } catch {
                    req.logger.warning("Translation failed for skip_additional chatId=\(chatId): \(error). Using Russian.")
                    englishPrompt = russianPrompt
                    await PhotoSessionManager.shared.setTranslatedPrompt(englishPrompt, for: chatId)
                }
            } else {
                req.logger.warning("Translation is disabled via DISABLE_TRANSLATION env flag; using Russian prompt for chatId=\(chatId) in skip_additional")
                englishPrompt = russianPrompt
                await PhotoSessionManager.shared.setTranslatedPrompt(englishPrompt, for: chatId)
            }
            
            // Показываем превью промпта и кнопку генерации
            let preview: String
            if translationDisabled {
                preview = """
Дополнительные детали пропущены. ✨

Вот составной промпт:
🇷🇺 \(russianPrompt.isEmpty ? "(пусто)" : russianPrompt)

Готов сгенерировать изображение?
"""
            } else {
                preview = """
Дополнительные детали пропущены. ✨

Вот составной промпт:
🇷🇺 Русский: \(russianPrompt.isEmpty ? "(пусто)" : russianPrompt)
🇬🇧 English: \(englishPrompt.isEmpty ? "(empty)" : englishPrompt)

Готов сгенерировать изображение?
"""
            }
            
            await PhotoSessionManager.shared.setPromptCollectionState(.readyToGenerate, for: chatId)
            
            let previewURL = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
            var previewRequest = ClientRequest(method: .POST, url: previewURL)
            let previewPayload = SendInlineMessagePayload(
                chat_id: chatId,
                text: preview,
                reply_markup: ReplyMarkup(inline_keyboard: [
                    [
                        InlineKeyboardButton(text: "✏️ Изменить место", callback_data: "edit_location"),
                        InlineKeyboardButton(text: "✏️ Изменить одежду", callback_data: "edit_clothing")
                    ],
                    [
                        InlineKeyboardButton(text: "✏️ Изменить детали", callback_data: "edit_details")
                    ],
                    [
                        InlineKeyboardButton(text: "✅ Сгенерировать", callback_data: "finalize_generate")
                    ]
                ])
            )
            previewRequest.headers.add(name: .contentType, value: "application/json")
            previewRequest.body = try .init(data: JSONEncoder().encode(previewPayload))
            _ = try await req.client.send(previewRequest)
            
        case "edit_location":
            let chatId: Int64
            if let messageChatId = callback.message?.chat.id {
                chatId = messageChatId
            } else {
                chatId = callback.from.id
            }
            
            try await answerCallbackQuery(token: token, callbackId: callback.id, text: "Редактируем место", req: req)
            await PhotoSessionManager.shared.setPromptCollectionState(.editingLocation, for: chatId)
            
            let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
            var request = ClientRequest(method: .POST, url: url)
            let payload = SendInlineMessagePayload(
                chat_id: chatId,
                text: "Опиши место действия заново:",
                reply_markup: ReplyMarkup(inline_keyboard: [])
            )
            request.headers.add(name: .contentType, value: "application/json")
            request.body = try .init(data: JSONEncoder().encode(payload))
            _ = try await req.client.send(request)
            
        case "edit_clothing":
            let chatId: Int64
            if let messageChatId = callback.message?.chat.id {
                chatId = messageChatId
            } else {
                chatId = callback.from.id
            }
            
            try await answerCallbackQuery(token: token, callbackId: callback.id, text: "Редактируем одежду", req: req)
            await PhotoSessionManager.shared.setPromptCollectionState(.editingClothing, for: chatId)
            
            let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
            var request = ClientRequest(method: .POST, url: url)
            let payload = SendInlineMessagePayload(
                chat_id: chatId,
                text: "Опиши одежду и её цвет заново:",
                reply_markup: ReplyMarkup(inline_keyboard: [])
            )
            request.headers.add(name: .contentType, value: "application/json")
            request.body = try .init(data: JSONEncoder().encode(payload))
            _ = try await req.client.send(request)
            
        case "edit_details":
            let chatId: Int64
            if let messageChatId = callback.message?.chat.id {
                chatId = messageChatId
            } else {
                chatId = callback.from.id
            }
            
            try await answerCallbackQuery(token: token, callbackId: callback.id, text: "Редактируем детали", req: req)
            await PhotoSessionManager.shared.setPromptCollectionState(.editingDetails, for: chatId)
            
            let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
            var request = ClientRequest(method: .POST, url: url)
            let payload = SendInlineMessagePayload(
                chat_id: chatId,
                text: "Добавь дополнительные детали заново (или напиши \"готово\" чтобы пропустить):",
                reply_markup: ReplyMarkup(inline_keyboard: [])
            )
            request.headers.add(name: .contentType, value: "application/json")
            request.body = try .init(data: JSONEncoder().encode(payload))
            _ = try await req.client.send(request)
            
        default:
            try await answerCallbackQuery(token: token, callbackId: callback.id, text: nil, req: req)
        }
    }

    private func answerCallbackQuery(token: String, callbackId: String, text: String?, req: Request) async throws {
        let url = URI(string: "https://api.telegram.org/bot\(token)/answerCallbackQuery")
        var request = ClientRequest(method: .POST, url: url)
        struct Payload: Encodable {
            let callback_query_id: String
            let text: String?
            let show_alert: Bool?
        }
        let payload = Payload(callback_query_id: callbackId, text: text, show_alert: text == nil ? nil : false)
        request.headers.add(name: .contentType, value: "application/json")
        request.body = try .init(data: JSONEncoder().encode(payload))
        _ = try await req.client.send(request)
    }
    
    // MARK: - Вспомогательные функции для дополнительных параметров
    
    private func showCategoryParams(chatId: Int64, token: String, category: String, req: Request) async throws {
        var keyboard: [[InlineKeyboardButton]] = []
        var messageText = ""
        var currentValue: String? = nil
        
        switch category {
        case "camera_angle":
            messageText = "📷 Угол камеры:"
            currentValue = await PhotoSessionManager.shared.getCameraAngle(for: chatId)
            keyboard.append([
                InlineKeyboardButton(text: currentValue == "front" ? "✅ Спереди" : "Спереди", callback_data: "select_param_camera_front"),
                InlineKeyboardButton(text: currentValue == "side" ? "✅ Сбоку" : "Сбоку", callback_data: "select_param_camera_side")
            ])
            keyboard.append([
                InlineKeyboardButton(text: currentValue == "back" ? "✅ Сзади" : "Сзади", callback_data: "select_param_camera_back"),
                InlineKeyboardButton(text: currentValue == "top" ? "✅ Сверху" : "Сверху", callback_data: "select_param_camera_top")
            ])
            keyboard.append([
                InlineKeyboardButton(text: currentValue == "low" ? "✅ Снизу" : "Снизу", callback_data: "select_param_camera_low"),
                InlineKeyboardButton(text: currentValue == "three_quarter" ? "✅ 3/4" : "3/4", callback_data: "select_param_camera_three_quarter")
            ])
            
        case "shot_size":
            messageText = "📐 Крупность плана:"
            currentValue = await PhotoSessionManager.shared.getShotSize(for: chatId)
            keyboard.append([
                InlineKeyboardButton(text: currentValue == "close_up" ? "✅ Крупный план" : "Крупный план", callback_data: "select_param_shot_close_up"),
                InlineKeyboardButton(text: currentValue == "medium" ? "✅ Средний план" : "Средний план", callback_data: "select_param_shot_medium")
            ])
            keyboard.append([
                InlineKeyboardButton(text: currentValue == "full_body" ? "✅ Общий план" : "Общий план", callback_data: "select_param_shot_full_body"),
                InlineKeyboardButton(text: currentValue == "portrait" ? "✅ Портрет" : "Портрет", callback_data: "select_param_shot_portrait")
            ])
            
        case "lighting":
            messageText = "💡 Освещение:"
            currentValue = await PhotoSessionManager.shared.getLighting(for: chatId)
            keyboard.append([
                InlineKeyboardButton(text: currentValue == "natural" ? "✅ Естественное" : "Естественное", callback_data: "select_param_lighting_natural"),
                InlineKeyboardButton(text: currentValue == "golden_hour" ? "✅ Золотой час" : "Золотой час", callback_data: "select_param_lighting_golden_hour")
            ])
            keyboard.append([
                InlineKeyboardButton(text: currentValue == "blue_hour" ? "✅ Синий час" : "Синий час", callback_data: "select_param_lighting_blue_hour"),
                InlineKeyboardButton(text: currentValue == "studio" ? "✅ Студийное" : "Студийное", callback_data: "select_param_lighting_studio")
            ])
            keyboard.append([
                InlineKeyboardButton(text: currentValue == "backlight" ? "✅ Контровое" : "Контровое", callback_data: "select_param_lighting_backlight"),
                InlineKeyboardButton(text: currentValue == "soft" ? "✅ Мягкое" : "Мягкое", callback_data: "select_param_lighting_soft")
            ])
            
        case "pose":
            messageText = "🧍 Поза:"
            currentValue = await PhotoSessionManager.shared.getPose(for: chatId)
            keyboard.append([
                InlineKeyboardButton(text: currentValue == "standing" ? "✅ Стоя" : "Стоя", callback_data: "select_param_pose_standing"),
                InlineKeyboardButton(text: currentValue == "sitting" ? "✅ Сидя" : "Сидя", callback_data: "select_param_pose_sitting")
            ])
            keyboard.append([
                InlineKeyboardButton(text: currentValue == "lying" ? "✅ Лежа" : "Лежа", callback_data: "select_param_pose_lying"),
                InlineKeyboardButton(text: currentValue == "motion" ? "✅ В движении" : "В движении", callback_data: "select_param_pose_motion")
            ])
            
        case "expression":
            messageText = "😊 Выражение лица:"
            currentValue = await PhotoSessionManager.shared.getExpression(for: chatId)
            keyboard.append([
                InlineKeyboardButton(text: currentValue == "smiling" ? "✅ Улыбка" : "Улыбка", callback_data: "select_param_expression_smiling"),
                InlineKeyboardButton(text: currentValue == "serious" ? "✅ Серьёзное" : "Серьёзное", callback_data: "select_param_expression_serious")
            ])
            keyboard.append([
                InlineKeyboardButton(text: currentValue == "looking_at_camera" ? "✅ Взгляд в камеру" : "Взгляд в камеру", callback_data: "select_param_expression_looking_at_camera"),
                InlineKeyboardButton(text: currentValue == "looking_away" ? "✅ Взгляд в сторону" : "Взгляд в сторону", callback_data: "select_param_expression_looking_away")
            ])
            
        case "focus":
            messageText = "🎯 Фокус:"
            currentValue = await PhotoSessionManager.shared.getFocus(for: chatId)
            keyboard.append([
                InlineKeyboardButton(text: currentValue == "sharp" ? "✅ Резкий" : "Резкий", callback_data: "select_param_focus_sharp"),
                InlineKeyboardButton(text: currentValue == "bokeh" ? "✅ Размытый фон" : "Размытый фон", callback_data: "select_param_focus_bokeh")
            ])
            
        default:
            return
        }
        
        // Добавляем кнопку "Назад"
        keyboard.append([InlineKeyboardButton(text: "⬅️ Назад к категориям", callback_data: "back_to_categories")])
        
        let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
        var request = ClientRequest(method: .POST, url: url)
        let payload = SendInlineMessagePayload(
            chat_id: chatId,
            text: messageText,
            reply_markup: ReplyMarkup(inline_keyboard: keyboard)
        )
        request.headers.add(name: .contentType, value: "application/json")
        request.body = try .init(data: JSONEncoder().encode(payload))
        _ = try await req.client.send(request)
    }
    
    private func hasParamSelected(chatId: Int64, category: String) async -> Bool {
        switch category {
        case "camera_angle":
            return await PhotoSessionManager.shared.getCameraAngle(for: chatId) != nil
        case "shot_size":
            return await PhotoSessionManager.shared.getShotSize(for: chatId) != nil
        case "lighting":
            return await PhotoSessionManager.shared.getLighting(for: chatId) != nil
        case "pose":
            return await PhotoSessionManager.shared.getPose(for: chatId) != nil
        case "expression":
            return await PhotoSessionManager.shared.getExpression(for: chatId) != nil
        case "focus":
            return await PhotoSessionManager.shared.getFocus(for: chatId) != nil
        default:
            return false
        }
    }
    
    private func showAdditionalParamsMenu(chatId: Int64, token: String, selectedCategories: Set<String>, req: Request) async throws {
        var keyboard: [[InlineKeyboardButton]] = []
        var messageText = "📸 Выбери параметры:\n\n"
        
        // Параметры для угла камеры
        if selectedCategories.contains("camera_angle") {
            let current = await PhotoSessionManager.shared.getCameraAngle(for: chatId)
            messageText += "📷 Угол камеры\(current != nil ? " (✅ \(current ?? "")" : ""):\n"
            keyboard.append([
                InlineKeyboardButton(text: current == "front" ? "✅ Спереди" : "Спереди", callback_data: "select_param_camera_front"),
                InlineKeyboardButton(text: current == "side" ? "✅ Сбоку" : "Сбоку", callback_data: "select_param_camera_side")
            ])
            keyboard.append([
                InlineKeyboardButton(text: current == "back" ? "✅ Сзади" : "Сзади", callback_data: "select_param_camera_back"),
                InlineKeyboardButton(text: current == "top" ? "✅ Сверху" : "Сверху", callback_data: "select_param_camera_top")
            ])
            keyboard.append([
                InlineKeyboardButton(text: current == "low" ? "✅ Снизу" : "Снизу", callback_data: "select_param_camera_low"),
                InlineKeyboardButton(text: current == "three_quarter" ? "✅ 3/4" : "3/4", callback_data: "select_param_camera_three_quarter")
            ])
            keyboard.append([]) // Пустая строка для разделения
        }
        
        // Параметры для крупности плана
        if selectedCategories.contains("shot_size") {
            let current = await PhotoSessionManager.shared.getShotSize(for: chatId)
            messageText += "📐 Крупность плана\(current != nil ? " (✅ \(current ?? "")" : ""):\n"
            keyboard.append([
                InlineKeyboardButton(text: current == "close_up" ? "✅ Крупный план" : "Крупный план", callback_data: "select_param_shot_close_up"),
                InlineKeyboardButton(text: current == "medium" ? "✅ Средний план" : "Средний план", callback_data: "select_param_shot_medium")
            ])
            keyboard.append([
                InlineKeyboardButton(text: current == "full_body" ? "✅ Общий план" : "Общий план", callback_data: "select_param_shot_full_body"),
                InlineKeyboardButton(text: current == "portrait" ? "✅ Портрет" : "Портрет", callback_data: "select_param_shot_portrait")
            ])
            keyboard.append([])
        }
        
        // Параметры для освещения
        if selectedCategories.contains("lighting") {
            let current = await PhotoSessionManager.shared.getLighting(for: chatId)
            messageText += "💡 Освещение\(current != nil ? " (✅ \(current ?? "")" : ""):\n"
            keyboard.append([
                InlineKeyboardButton(text: current == "natural" ? "✅ Естественное" : "Естественное", callback_data: "select_param_lighting_natural"),
                InlineKeyboardButton(text: current == "golden_hour" ? "✅ Золотой час" : "Золотой час", callback_data: "select_param_lighting_golden_hour")
            ])
            keyboard.append([
                InlineKeyboardButton(text: current == "blue_hour" ? "✅ Синий час" : "Синий час", callback_data: "select_param_lighting_blue_hour"),
                InlineKeyboardButton(text: current == "studio" ? "✅ Студийное" : "Студийное", callback_data: "select_param_lighting_studio")
            ])
            keyboard.append([
                InlineKeyboardButton(text: current == "backlight" ? "✅ Контровое" : "Контровое", callback_data: "select_param_lighting_backlight"),
                InlineKeyboardButton(text: current == "soft" ? "✅ Мягкое" : "Мягкое", callback_data: "select_param_lighting_soft")
            ])
            keyboard.append([])
        }
        
        // Параметры для позы
        if selectedCategories.contains("pose") {
            let current = await PhotoSessionManager.shared.getPose(for: chatId)
            messageText += "🧍 Поза\(current != nil ? " (✅ \(current ?? "")" : ""):\n"
            keyboard.append([
                InlineKeyboardButton(text: current == "standing" ? "✅ Стоя" : "Стоя", callback_data: "select_param_pose_standing"),
                InlineKeyboardButton(text: current == "sitting" ? "✅ Сидя" : "Сидя", callback_data: "select_param_pose_sitting")
            ])
            keyboard.append([
                InlineKeyboardButton(text: current == "lying" ? "✅ Лежа" : "Лежа", callback_data: "select_param_pose_lying"),
                InlineKeyboardButton(text: current == "motion" ? "✅ В движении" : "В движении", callback_data: "select_param_pose_motion")
            ])
            keyboard.append([])
        }
        
        // Параметры для выражения лица
        if selectedCategories.contains("expression") {
            let current = await PhotoSessionManager.shared.getExpression(for: chatId)
            messageText += "😊 Выражение лица\(current != nil ? " (✅ \(current ?? "")" : ""):\n"
            keyboard.append([
                InlineKeyboardButton(text: current == "smiling" ? "✅ Улыбка" : "Улыбка", callback_data: "select_param_expression_smiling"),
                InlineKeyboardButton(text: current == "serious" ? "✅ Серьёзное" : "Серьёзное", callback_data: "select_param_expression_serious")
            ])
            keyboard.append([
                InlineKeyboardButton(text: current == "looking_at_camera" ? "✅ Взгляд в камеру" : "Взгляд в камеру", callback_data: "select_param_expression_looking_at_camera"),
                InlineKeyboardButton(text: current == "looking_away" ? "✅ Взгляд в сторону" : "Взгляд в сторону", callback_data: "select_param_expression_looking_away")
            ])
            keyboard.append([])
        }
        
        // Параметры для фокуса
        if selectedCategories.contains("focus") {
            let current = await PhotoSessionManager.shared.getFocus(for: chatId)
            messageText += "🎯 Фокус\(current != nil ? " (✅ \(current ?? "")" : ""):\n"
            keyboard.append([
                InlineKeyboardButton(text: current == "sharp" ? "✅ Резкий" : "Резкий", callback_data: "select_param_focus_sharp"),
                InlineKeyboardButton(text: current == "bokeh" ? "✅ Размытый фон" : "Размытый фон", callback_data: "select_param_focus_bokeh")
            ])
            keyboard.append([])
        }
        
        // Убираем последнюю пустую строку если есть
        if keyboard.last?.isEmpty == true {
            keyboard.removeLast()
        }
        
        let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
        var request = ClientRequest(method: .POST, url: url)
        let payload = SendInlineMessagePayload(
            chat_id: chatId,
            text: messageText,
            reply_markup: ReplyMarkup(inline_keyboard: keyboard)
        )
        request.headers.add(name: .contentType, value: "application/json")
        request.body = try .init(data: JSONEncoder().encode(payload))
        _ = try await req.client.send(request)
    }
    
    private func checkAllParamsSelected(chatId: Int64, categories: Set<String>) async -> Bool {
        for category in categories {
            switch category {
            case "camera_angle":
                if await PhotoSessionManager.shared.getCameraAngle(for: chatId) == nil {
                    return false
                }
            case "shot_size":
                if await PhotoSessionManager.shared.getShotSize(for: chatId) == nil {
                    return false
                }
            case "lighting":
                if await PhotoSessionManager.shared.getLighting(for: chatId) == nil {
                    return false
                }
            case "pose":
                if await PhotoSessionManager.shared.getPose(for: chatId) == nil {
                    return false
                }
            case "expression":
                if await PhotoSessionManager.shared.getExpression(for: chatId) == nil {
                    return false
                }
            case "focus":
                if await PhotoSessionManager.shared.getFocus(for: chatId) == nil {
                    return false
                }
            default:
                break
            }
        }
        return true
    }
    
    private func showFinalAdditionalStep(chatId: Int64, token: String, req: Request) async throws {
        let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
        var request = ClientRequest(method: .POST, url: url)
        let payload = SendInlineMessagePayload(
            chat_id: chatId,
            text: "Параметры сохранены! ✨\n\nХочешь добавить что-то ещё текстом?\n(Например: \"с книгой в руках\", \"на фоне гор\")",
            reply_markup: ReplyMarkup(inline_keyboard: [
                [InlineKeyboardButton(text: "➕ Добавить текст", callback_data: "add_text_additional")],
                [InlineKeyboardButton(text: "✅ Готово, сгенерировать", callback_data: "finish_additional_without_text")]
            ])
        )
        request.headers.add(name: .contentType, value: "application/json")
        request.body = try .init(data: JSONEncoder().encode(payload))
        _ = try await req.client.send(request)
    }
    
    private func showPromptPreview(chatId: Int64, token: String, req: Request) async throws {
        let location = await PhotoSessionManager.shared.getUserLocation(for: chatId) ?? ""
        let clothing = await PhotoSessionManager.shared.getUserClothing(for: chatId) ?? ""
        
        // Собираем дополнительные параметры
        var additionalParams: [String] = []
        if let angle = await PhotoSessionManager.shared.getCameraAngle(for: chatId) {
            let angleNames: [String: String] = [
                "front": "спереди",
                "side": "сбоку",
                "back": "сзади",
                "top": "сверху",
                "low": "снизу",
                "three_quarter": "3/4"
            ]
            additionalParams.append(angleNames[angle] ?? angle)
        }
        if let size = await PhotoSessionManager.shared.getShotSize(for: chatId) {
            let sizeNames: [String: String] = [
                "close_up": "крупный план",
                "medium": "средний план",
                "full_body": "общий план",
                "portrait": "портрет"
            ]
            additionalParams.append(sizeNames[size] ?? size)
        }
        if let lighting = await PhotoSessionManager.shared.getLighting(for: chatId) {
            let lightingNames: [String: String] = [
                "natural": "естественное освещение",
                "golden_hour": "золотой час",
                "blue_hour": "синий час",
                "studio": "студийное освещение",
                "backlight": "контровое освещение",
                "soft": "мягкое освещение"
            ]
            additionalParams.append(lightingNames[lighting] ?? lighting)
        }
        if let pose = await PhotoSessionManager.shared.getPose(for: chatId) {
            let poseNames: [String: String] = [
                "standing": "стоя",
                "sitting": "сидя",
                "lying": "лежа",
                "motion": "в движении"
            ]
            additionalParams.append(poseNames[pose] ?? pose)
        }
        if let expression = await PhotoSessionManager.shared.getExpression(for: chatId) {
            let expressionNames: [String: String] = [
                "smiling": "улыбка",
                "serious": "серьёзное",
                "looking_at_camera": "взгляд в камеру",
                "looking_away": "взгляд в сторону"
            ]
            additionalParams.append(expressionNames[expression] ?? expression)
        }
        if let focus = await PhotoSessionManager.shared.getFocus(for: chatId) {
            let focusNames: [String: String] = [
                "sharp": "резкий фокус",
                "bokeh": "размытый фон"
            ]
            additionalParams.append(focusNames[focus] ?? focus)
        }
        
        let additionalDetails = await PhotoSessionManager.shared.getAdditionalDetails(for: chatId) ?? ""
        
        // Формируем русский промпт
        var promptParts: [String] = []
        if !location.isEmpty {
            promptParts.append("в \(location)")
        }
        if !clothing.isEmpty {
            promptParts.append("в \(clothing)")
        }
        if !additionalParams.isEmpty {
            promptParts.append(additionalParams.joined(separator: ", "))
        }
        if !additionalDetails.isEmpty {
            promptParts.append(additionalDetails)
        }
        let russianPrompt = promptParts.joined(separator: ", ")
        
        // Переводим на английский
        let translationDisabled = Environment.get("DISABLE_TRANSLATION")?.lowercased() == "true"
        let englishPrompt: String
        if !translationDisabled {
            do {
                let translator = try YandexTranslationClient(request: req)
                englishPrompt = try await translator.translateToEnglish(russianPrompt)
                await PhotoSessionManager.shared.setTranslatedPrompt(englishPrompt, for: chatId)
            } catch {
                req.logger.warning("Translation failed for preview chatId=\(chatId): \(error). Using Russian.")
                englishPrompt = russianPrompt
                await PhotoSessionManager.shared.setTranslatedPrompt(englishPrompt, for: chatId)
            }
        } else {
            englishPrompt = russianPrompt
            await PhotoSessionManager.shared.setTranslatedPrompt(englishPrompt, for: chatId)
        }
        
        // Показываем превью
        let preview: String
        if translationDisabled {
            preview = """
Дополнительные детали сохранены! ✨

Вот составной промпт:
🇷🇺 \(russianPrompt.isEmpty ? "(пусто)" : russianPrompt)

Готов сгенерировать изображение?
"""
        } else {
            preview = """
Дополнительные детали сохранены! ✨

Вот составной промпт:
🇷🇺 Русский: \(russianPrompt.isEmpty ? "(пусто)" : russianPrompt)
🇬🇧 English: \(englishPrompt.isEmpty ? "(empty)" : englishPrompt)

Готов сгенерировать изображение?
"""
        }
        
        await PhotoSessionManager.shared.setPromptCollectionState(.readyToGenerate, for: chatId)
        
        let previewURL = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
        var previewRequest = ClientRequest(method: .POST, url: previewURL)
        let previewPayload = SendInlineMessagePayload(
            chat_id: chatId,
            text: preview,
            reply_markup: ReplyMarkup(inline_keyboard: [
                [
                    InlineKeyboardButton(text: "✏️ Изменить место", callback_data: "edit_location"),
                    InlineKeyboardButton(text: "✏️ Изменить одежду", callback_data: "edit_clothing")
                ],
                [
                    InlineKeyboardButton(text: "✏️ Изменить детали", callback_data: "edit_details")
                ],
                [
                    InlineKeyboardButton(text: "✅ Сгенерировать", callback_data: "finalize_generate")
                ]
            ])
        )
        previewRequest.headers.add(name: .contentType, value: "application/json")
        previewRequest.body = try .init(data: JSONEncoder().encode(previewPayload))
        _ = try await req.client.send(previewRequest)
    }
} 

private struct TelegramFileResponse: Decodable {
    let ok: Bool
    let result: TelegramFile
}

private struct TelegramFile: Decodable {
    let file_id: String
    let file_unique_id: String
    let file_size: Int?
    let file_path: String?
}

private struct SendInlineMessagePayload: Encodable {
    let chat_id: Int64
    let text: String
    let reply_markup: ReplyMarkup
}

private struct ReplyMarkup: Encodable {
    let inline_keyboard: [[InlineKeyboardButton]]
}

private struct InlineKeyboardButton: Encodable {
    let text: String
    let callback_data: String
} 