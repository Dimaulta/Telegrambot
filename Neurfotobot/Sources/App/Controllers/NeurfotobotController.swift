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
                
                // Отправляем сообщение с инструкциями
                let successText = "Можешь обучить модель нажав /train или добавить ещё фотографии"
                _ = try? await sendTelegramMessage(
                    token: token,
                    chatId: message.chat.id,
                    text: successText,
                    client: req.client
                )
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
        case .genderSelected:
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
            if text.lowercased().trimmingCharacters(in: .whitespaces) == "готово" || text.lowercased().trimmingCharacters(in: .whitespaces) == "готов" {
                // Пользователь написал "готово", пропускаем дополнительные детали
                await PhotoSessionManager.shared.setAdditionalDetails("", for: chatId)
            } else {
                await PhotoSessionManager.shared.setAdditionalDetails(text, for: chatId)
            }
            await PhotoSessionManager.shared.setPromptCollectionState(.readyToGenerate, for: chatId)
            
            // Собираем составной промпт для показа пользователю
            let location = await PhotoSessionManager.shared.getUserLocation(for: chatId) ?? ""
            let clothing = await PhotoSessionManager.shared.getUserClothing(for: chatId) ?? ""
            let details = await PhotoSessionManager.shared.getAdditionalDetails(for: chatId) ?? ""
            
            // Формируем русский промпт для показа
            var promptParts: [String] = []
            if !location.isEmpty {
                promptParts.append("в \(location)")
            }
            if !clothing.isEmpty {
                promptParts.append("в \(clothing)")
            }
            if !details.isEmpty {
                promptParts.append(details)
            }
            let russianPrompt = promptParts.joined(separator: ", ")
            
            // Переводим на английский для показа (если перевод не отключен)
            let translationDisabled = Environment.get("DISABLE_TRANSLATION")?.lowercased() == "true"
            let englishPrompt: String
            if !translationDisabled {
                do {
                    let translator = try YandexTranslationClient(request: req)
                    englishPrompt = try await translator.translateToEnglish(russianPrompt)
                    // Сохраняем переведённый промпт, чтобы не переводить дважды
                    await PhotoSessionManager.shared.setTranslatedPrompt(englishPrompt, for: chatId)
                } catch {
                    req.logger.warning("Translation failed for preview chatId=\(chatId): \(error). Using Russian.")
                    englishPrompt = russianPrompt
                    await PhotoSessionManager.shared.setTranslatedPrompt(englishPrompt, for: chatId)
                }
            } else {
                req.logger.warning("Translation is disabled via DISABLE_TRANSLATION env flag; using Russian prompt for chatId=\(chatId)")
                englishPrompt = russianPrompt
                await PhotoSessionManager.shared.setTranslatedPrompt(englishPrompt, for: chatId)
            }
            
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
            
            let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
            var request = ClientRequest(method: .POST, url: url)
            let payload = SendInlineMessagePayload(
                chat_id: chatId,
                text: preview,
                reply_markup: ReplyMarkup(inline_keyboard: [
                    [InlineKeyboardButton(text: "✅ Сгенерировать", callback_data: "finalize_generate")]
                ])
            )
            request.headers.add(name: .contentType, value: "application/json")
            request.body = try .init(data: JSONEncoder().encode(payload))
            _ = try await req.client.send(request)
            return
            
        case .idle:
            // Если пользователь просто отправил текст без выбора стиля, показываем кнопки выбора стиля
            let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
            var request = ClientRequest(method: .POST, url: url)
            let payload = SendInlineMessagePayload(
                chat_id: chatId,
                text: "Выбери стиль генерации, затем опиши образ. Например: \"я в чёрном пальто в осеннем Париже\"",
                reply_markup: ReplyMarkup(inline_keyboard: [
                    [InlineKeyboardButton(text: "🎬 Кинематографично", callback_data: "style_cinematic")],
                    [InlineKeyboardButton(text: "🎨 Аниме", callback_data: "style_anime")],
                    [InlineKeyboardButton(text: "🤖 Киберпанк", callback_data: "style_cyberpunk")],
                    [InlineKeyboardButton(text: "📸 Обычное фото", callback_data: "style_photo")]
                ])
            )
            request.headers.add(name: .contentType, value: "application/json")
            request.body = try .init(data: JSONEncoder().encode(payload))
            _ = try await req.client.send(request)
            return
            
        case .styleSelected, .readyToGenerate:
            // Если уже выбран стиль или готово к генерации, просто возвращаемся
            return
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
        let gender = await PhotoSessionManager.shared.getUserGender(for: chatId) ?? ""
        let location = await PhotoSessionManager.shared.getUserLocation(for: chatId) ?? ""
        let clothing = await PhotoSessionManager.shared.getUserClothing(for: chatId) ?? ""
        let additionalDetails = await PhotoSessionManager.shared.getAdditionalDetails(for: chatId) ?? ""
        
        // Формируем промпт: место + одежда + дополнительные детали
        var promptParts: [String] = []
        if !location.isEmpty {
            promptParts.append("в \(location)")
        }
        if !clothing.isEmpty {
            promptParts.append("в \(clothing)")
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
        
        // Сохраняем пол для использования в промпте (чтобы модель знала пол)
        await PhotoSessionManager.shared.setPrompt(translatedPrompt, for: chatId)
        
        // Очищаем состояние сбора промпта
        await PhotoSessionManager.shared.clearPromptCollectionData(for: chatId)
        
        let application = req.application
        let logger = req.logger
        Task.detached {
            await NeurfotobotPipelineService.shared.generateImages(
                chatId: chatId,
                prompt: translatedPrompt,
                userGender: gender,
                botToken: token,
                application: application,
                logger: logger
            )
        }
    }

    private func handleModelCommand(chatId: Int64, token: String, req: Request) async throws {
        let modelVersion = await PhotoSessionManager.shared.getModelVersion(for: chatId)
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
        let modelVersion = await PhotoSessionManager.shared.getModelVersion(for: chatId)
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

        // Показываем кнопки выбора стиля
        let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
        var request = ClientRequest(method: .POST, url: url)
        let payload = SendInlineMessagePayload(
            chat_id: chatId,
            text: "Выбери стиль генерации, затем опиши образ. Например: \"я в чёрном пальто в осеннем Париже\"",
            reply_markup: ReplyMarkup(inline_keyboard: [
                [InlineKeyboardButton(text: "🎬 Кинематографично", callback_data: "style_cinematic")],
                [InlineKeyboardButton(text: "🎨 Аниме", callback_data: "style_anime")],
                [InlineKeyboardButton(text: "🤖 Киберпанк", callback_data: "style_cyberpunk")],
                [InlineKeyboardButton(text: "📸 Обычное фото", callback_data: "style_photo")]
            ])
        )
        request.headers.add(name: .contentType, value: "application/json")
        request.body = try .init(data: JSONEncoder().encode(payload))
        _ = try await req.client.send(request)
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
            
            let modelVersion = await PhotoSessionManager.shared.getModelVersion(for: chatId)
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
            
            try await answerCallbackQuery(token: token, callbackId: callback.id, text: "Запускаю генерацию...", req: req)
            try await finalizeAndGeneratePrompt(chatId: chatId, token: token, req: req)
            
        case "style_cinematic", "style_anime", "style_cyberpunk", "style_photo":
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
            
            // Показываем текст и кнопку, чтобы можно было пропустить дополнительные детали
            let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
            var request = ClientRequest(method: .POST, url: url)
            let payload = SendInlineMessagePayload(
                chat_id: chatId,
                text: "Хочешь добавить что-то ещё? Опиши дополнительные детали сообщением.\n\nЕсли ничего добавлять не нужно — нажми \"⏭ Пропустить\".",
                reply_markup: ReplyMarkup(inline_keyboard: [
                    [InlineKeyboardButton(text: "⏭ Пропустить", callback_data: "skip_additional")]
                ])
            )
            request.headers.add(name: .contentType, value: "application/json")
            request.body = try .init(data: JSONEncoder().encode(payload))
            _ = try await req.client.send(request)

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
            
            let previewURL = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
            var previewRequest = ClientRequest(method: .POST, url: previewURL)
            let previewPayload = SendInlineMessagePayload(
                chat_id: chatId,
                text: preview,
                reply_markup: ReplyMarkup(inline_keyboard: [
                    [InlineKeyboardButton(text: "✅ Сгенерировать", callback_data: "finalize_generate")]
                ])
            )
            previewRequest.headers.add(name: .contentType, value: "application/json")
            previewRequest.body = try .init(data: JSONEncoder().encode(previewPayload))
            _ = try await req.client.send(previewRequest)
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