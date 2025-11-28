import Vapor
import Foundation

final class NeurfotobotController {
    private let minimumPhotoCount = 5
    private let maximumPhotoCount = 10

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
            try await handleCallback(callback, token: token, req: req)
            return Response(status: .ok)
        }

        guard let message = update.message else {
            req.logger.info("No message payload in update \(update.update_id)")
            return Response(status: .ok)
        }

        let text = message.text ?? ""
        if text == "/start" {
            await PhotoSessionManager.shared.reset(for: message.chat.id)
            let welcomeMessage = """
Привет! Загрузи от пяти до десяти своих фотографий, где хорошо видно лицо. Я соберу модель за несколько минут и по твоему промпту верну фото с твоим участием!

⏳ Обычно всё готово за несколько минут. Мы сообщим, когда модель соберётся и можно будет придумать образ. Чтобы всем было комфортно, автоматически проверяем фотографии через SafeSearch, а промпты через OpenAI Moderation. Добросовестных пользователей это никак не затрагивает, но любой незаконный контент блокируется и фиксируется в логах
"""

            do {
                try await sendTelegramMessage(
                    token: token,
                    chatId: message.chat.id,
                    text: welcomeMessage,
                    client: req.client
                )
            } catch {
                req.logger.error("Failed to send welcome message: \(error)")
            }
        }

        if text == "/train" {
            try await handleTrainCommand(chatId: message.chat.id, token: token, req: req)
            return Response(status: .ok)
        }

        if !text.isEmpty && text != "/start" && text != "/model" && text != "/train" {
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
        var buffer = ByteBufferAllocator().buffer(capacity: fileData.count)
        buffer.writeBytes(fileData)

        let ext = (filePath as NSString).pathExtension.lowercased()
        let finalExt = ext.isEmpty ? "jpg" : ext
        let contentType = mimeType(for: finalExt)
        let storage = try SupabaseStorageClient(request: req)
        let objectPath = "\(message.chat.id)/\(UUID().uuidString).\(finalExt)"

        let storedPath = try await storage.upload(path: objectPath, data: buffer, contentType: contentType)
        req.logger.info("Uploaded photo stored at \(storedPath)")
        let newCount = await PhotoSessionManager.shared.addPhoto(path: storedPath, for: message.chat.id)
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
        let storage = try SupabaseStorageClient(request: req)
        let photos = await PhotoSessionManager.shared.getPhotos(for: chatId)
        let riskyLevels: Set<String> = ["LIKELY", "VERY_LIKELY"]
        let safeSearchDisabled = Environment.get("DISABLE_SAFESEARCH")?.lowercased() == "true"

        if !safeSearchDisabled {
            let vision = try GoogleVisionClient(request: req)

            for photo in photos {
                do {
                    req.logger.info("Validating photo at path \(photo.path)")
                    let data = try await storage.download(path: photo.path)
                    let annotation = try await vision.analyzeSafeSearch(data: data)
                    if riskyLevels.contains(annotation.adult) ||
                        riskyLevels.contains(annotation.violence ?? "") ||
                        riskyLevels.contains(annotation.racy ?? "") ||
                        riskyLevels.contains(annotation.medical ?? "") {
                        try await handleModerationFail(chatId: chatId, token: token, storage: storage, photos: photos, req: req)
                        return
                    }
                } catch {
                    req.logger.error("SafeSearch check failed for \(photo.path): \(error)")
                    try await handleModerationFail(chatId: chatId, token: token, storage: storage, photos: photos, req: req)
                    return
                }
            }
        } else {
            req.logger.warning("SafeSearch is disabled via DISABLE_SAFESEARCH env flag; skipping moderation for chat \(chatId)")
        }

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

    private func handleModerationFail(chatId: Int64, token: String, storage: SupabaseStorageClient, photos: [PhotoSessionManager.PhotoRecord], req: Request) async throws {
        for photo in photos {
            try? await storage.delete(path: photo.path)
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
        let trainingState = await PhotoSessionManager.shared.getTrainingState(for: message.chat.id)
        switch trainingState {
        case .idle:
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: message.chat.id,
                text: "Сначала пришли минимум \(minimumPhotoCount) фото (можно до \(maximumPhotoCount)), чтобы я могла обучить модель.",
                client: req.client
            )
            return
        case .training:
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: message.chat.id,
                text: "Я всё ещё обучаю модель. Как только закончу, сразу попрошу описать образ.",
                client: req.client
            )
            return
        case .failed:
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: message.chat.id,
                text: "Обучение модели не удалось. Попробуй начать заново.",
                client: req.client
            )
            return
        case .ready:
            break
        }

        let moderation = try OpenAIModerationClient(request: req)
        let analysis = try await moderation.analyze(text: text)
        guard !analysis.flagged else {
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: message.chat.id,
                text: "Текст содержит запрещённые темы (\(analysis.violations.joined(separator: ", "))). Попробуй описать образ по-другому.",
                client: req.client
            )
            return
        }

        await PhotoSessionManager.shared.setPrompt(text, for: message.chat.id)
        let application = req.application
        let logger = req.logger
        Task.detached {
            await NeurfotobotPipelineService.shared.generateImages(chatId: message.chat.id, prompt: text, botToken: token, application: application, logger: logger)
        }
    }

    private func handleModelCommand(chatId: Int64, token: String, req: Request) async throws {
        let modelVersion = await PhotoSessionManager.shared.getModelVersion(for: chatId)
        if let modelVersion {
            let message = "Твоя модель готова и доступна по версии \(modelVersion). Можешь генерировать образы или удалить модель, если больше не нужна."
            let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
            var request = ClientRequest(method: .POST, url: url)
            let payload = SendInlineMessagePayload(
                chat_id: chatId,
                text: message,
                reply_markup: ReplyMarkup(inline_keyboard: [[InlineKeyboardButton(text: "Удалить модель", callback_data: "delete_model")]])
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