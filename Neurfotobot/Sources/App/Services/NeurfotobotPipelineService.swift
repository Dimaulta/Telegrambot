import Vapor
import Foundation

actor NeurfotobotPipelineService {
    static let shared = NeurfotobotPipelineService()

    func startTraining(chatId: Int64, botToken: String, application: Application, logger: Logger) async {
        await PhotoSessionManager.shared.setTrainingState(.training, for: chatId)

        let photos = await PhotoSessionManager.shared.getPhotos(for: chatId)
        guard photos.count >= 8 else {
            logger.warning("Not enough photos to start training for chatId=\(chatId)")
            return
        }

        do {
            let datasetBuilder = try DatasetBuilder(application: application, logger: logger)
            let dataset = try await datasetBuilder.buildDataset(for: chatId, photos: photos)
            await PhotoSessionManager.shared.setDatasetPath(dataset.datasetPath, for: chatId)

            let replicate = try ReplicateClient(application: application, logger: logger)
            let destinationModel = replicate.destinationModelName(for: chatId)
            let training = try await replicate.startTraining(destinationModel: destinationModel, datasetURL: dataset.signedURL, conceptName: "user\(chatId)")
            await PhotoSessionManager.shared.setTrainingId(training.id, for: chatId)

            try await sendMessage(token: botToken, chatId: chatId, text: "Запустила обучение персональной модели. Это займёт несколько минут, я напишу, когда всё будет готово.", application: application)

            var currentStatus = training.status
            while true {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                let status = try await replicate.fetchTraining(id: training.id)
                if status.status != currentStatus {
                    logger.info("Training status for chatId=\(chatId) changed: \(currentStatus) -> \(status.status)")
                    currentStatus = status.status
                }
                switch status.status.lowercased() {
                case "succeeded":
                    let version = status.output?.version ?? replicate.defaultPredictionVersion
                    await PhotoSessionManager.shared.setModelVersion(version, for: chatId)
                    await PhotoSessionManager.shared.setTrainingState(.ready, for: chatId)
                    try await sendMessage(token: botToken, chatId: chatId, text: "Модель обучена! Теперь опиши образ — например: \"я в чёрном пальто в осеннем Париже\".", application: application)
                    return
                case "failed", "canceled":
                    await PhotoSessionManager.shared.setTrainingState(.failed, for: chatId)
                    try await sendMessage(token: botToken, chatId: chatId, text: "К сожалению, обучение модели не удалось. Попробуй позже или с другими фото.", application: application)
                    await datasetBuilder.deleteDataset(at: dataset.datasetPath)
                    await PhotoSessionManager.shared.setDatasetPath(nil, for: chatId)
                    try? await deleteOriginalPhotos(chatId: chatId, application: application, logger: logger)
                    return
                default:
                    continue
                }
            }
        } catch {
            logger.error("Training pipeline failed for chatId=\(chatId): \(error)")
            await PhotoSessionManager.shared.setTrainingState(.failed, for: chatId)
            if let datasetPath = await PhotoSessionManager.shared.getDatasetPath(for: chatId) {
                if let datasetBuilder = try? DatasetBuilder(application: application, logger: logger) {
                    await datasetBuilder.deleteDataset(at: datasetPath)
                }
                await PhotoSessionManager.shared.setDatasetPath(nil, for: chatId)
            }
            try? await deleteOriginalPhotos(chatId: chatId, application: application, logger: logger)
            try? await sendMessage(token: botToken, chatId: chatId, text: "Что-то пошло не так при обучении модели. Попробуй ещё раз позже.", application: application)
        }
    }

    func generateImages(chatId: Int64, prompt: String, botToken: String, application: Application, logger: Logger) async {
        guard let modelVersion = await PhotoSessionManager.shared.getModelVersion(for: chatId) else {
            logger.warning("Model version missing for chatId=\(chatId)")
            return
        }

        do {
            let replicate = try ReplicateClient(application: application, logger: logger)
            try await sendMessage(token: botToken, chatId: chatId, text: "Запускаю генерацию, подожди немного...", application: application)

            let prediction = try await replicate.generateImages(modelVersion: modelVersion, prompt: prompt)
            let final = try await replicate.waitForPrediction(id: prediction.id)

            guard final.status.lowercased() == "succeeded", let outputs = final.output else {
                try await sendMessage(token: botToken, chatId: chatId, text: "Не удалось получить изображения. Попробуй сформулировать промпт иначе.", application: application)
                return
            }

            for url in outputs.prefix(4) {
                try await sendPhoto(token: botToken, chatId: chatId, imageURL: url, application: application)
            }

            if let datasetPath = await PhotoSessionManager.shared.getDatasetPath(for: chatId) {
                let datasetBuilder = try DatasetBuilder(application: application, logger: logger)
                await datasetBuilder.deleteDataset(at: datasetPath)
                await PhotoSessionManager.shared.setDatasetPath(nil, for: chatId)
            }

            try await deleteOriginalPhotos(chatId: chatId, application: application, logger: logger)
            await PhotoSessionManager.shared.clearPhotos(for: chatId)
            await PhotoSessionManager.shared.setTrainingState(.ready, for: chatId)
            await PhotoSessionManager.shared.clearPrompt(for: chatId)

            try await sendMessage(token: botToken, chatId: chatId, text: "Готово! Исходные фото я удалила, модель сохранится на нашей стороне. Управлять моделью можно командой /model.", application: application)
        } catch {
            logger.error("Prediction pipeline failed for chatId=\(chatId): \(error)")
            try? await sendMessage(token: botToken, chatId: chatId, text: "Не получилось сгенерировать изображения. Попробуй ещё раз или уточни описание.", application: application)
        }
    }

    func deleteModel(chatId: Int64, botToken: String, application: Application, logger: Logger) async {
        do {
            let replicate = try ReplicateClient(application: application, logger: logger)
            let destinationModel = replicate.destinationModelName(for: chatId)
            try await replicate.deleteModel(destinationModel: destinationModel)
            if let datasetPath = await PhotoSessionManager.shared.getDatasetPath(for: chatId) {
                let datasetBuilder = try DatasetBuilder(application: application, logger: logger)
                await datasetBuilder.deleteDataset(at: datasetPath)
            }
            try await deleteOriginalPhotos(chatId: chatId, application: application, logger: logger)
            await PhotoSessionManager.shared.reset(for: chatId)
            try await sendMessage(token: botToken, chatId: chatId, text: "Модель и все связанные данные удалены. Если захочешь — можем обучить новую.", application: application)
        } catch {
            logger.error("Failed to delete model for chatId=\(chatId): \(error)")
            try? await sendMessage(token: botToken, chatId: chatId, text: "Не удалось удалить модель. Попробуй позже.", application: application)
        }
    }

    private func deleteOriginalPhotos(chatId: Int64, application: Application, logger: Logger) async throws {
        let photos = await PhotoSessionManager.shared.getPhotos(for: chatId)
        guard !photos.isEmpty else { return }
        let storage = try SupabaseStorageClient(application: application)
        for photo in photos {
            try? await storage.delete(path: photo.path)
        }
        logger.info("Deleted original photos for chatId=\(chatId)")
    }

    private func sendMessage(token: String, chatId: Int64, text: String, application: Application, replyMarkup: ReplyMarkup? = nil) async throws {
        let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
        var request = ClientRequest(method: .POST, url: url)
        request.headers.add(name: .contentType, value: "application/json")
        let payload = SendMessagePayload(chat_id: chatId, text: text, reply_markup: replyMarkup)
        request.body = try .init(data: JSONEncoder().encode(payload))
        _ = try await application.client.send(request)
    }

    private func sendPhoto(token: String, chatId: Int64, imageURL: String, application: Application) async throws {
        let endpoint = URI(string: "https://api.telegram.org/bot\(token)/sendPhoto")
        var request = ClientRequest(method: .POST, url: endpoint)
        let payload: [String: String] = ["chat_id": String(chatId), "photo": imageURL]
        request.headers.add(name: .contentType, value: "application/json")
        request.body = try .init(data: JSONEncoder().encode(payload))
        _ = try await application.client.send(request)
    }
}

fileprivate struct SendMessagePayload: Encodable {
    let chat_id: Int64
    let text: String
    let reply_markup: ReplyMarkup?
}

fileprivate struct ReplyMarkup: Encodable {
    let inline_keyboard: [[InlineKeyboardButton]]
}

fileprivate struct InlineKeyboardButton: Encodable {
    let text: String
    let callback_data: String
}

