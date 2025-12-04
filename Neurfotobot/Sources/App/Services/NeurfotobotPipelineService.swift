import Vapor
import Foundation
import Fluent

actor NeurfotobotPipelineService {
    static let shared = NeurfotobotPipelineService()

    func startTraining(chatId: Int64, botToken: String, application: Application, logger: Logger) async {
        await PhotoSessionManager.shared.setTrainingState(.training, for: chatId)

        let photos = await PhotoSessionManager.shared.getPhotos(for: chatId)
        guard photos.count >= 5 else {
            logger.warning("Not enough photos to start training for chatId=\(chatId)")
            return
        }

        let keepArtifactsOnFailure = Environment.get("KEEP_DATASETS_ON_FAILURE")?.lowercased() == "true"

        do {
            let datasetBuilder = try DatasetBuilder(application: application, logger: logger)
            let dataset = try await datasetBuilder.buildDataset(for: chatId, photos: photos)
            await PhotoSessionManager.shared.setDatasetPath(dataset.datasetPath, for: chatId)

            do {
                let headRequest = ClientRequest(method: .HEAD, url: URI(string: dataset.publicURL))
                let headResponse = try await application.client.send(headRequest)
                logger.info("Dataset HEAD request status for chatId=\(chatId): \(headResponse.status)")
            } catch {
                logger.warning("Failed to verify dataset availability for chatId=\(chatId): \(error)")
            }

            let replicate = try ReplicateClient(application: application, logger: logger)
            let destinationModel = replicate.destinationModelName(for: chatId)
            let training = try await replicate.startTraining(destinationModel: destinationModel, datasetURL: dataset.publicURL, conceptName: "user\(chatId)")
            await PhotoSessionManager.shared.setTrainingId(training.id, for: chatId)

            try await sendMessage(token: botToken, chatId: chatId, text: "Запустила обучение персональной модели. Это займёт несколько минут, я напишу, когда всё будет готово.", application: application)

            var currentStatus = training.status
            var consecutiveErrors = 0
            let maxConsecutiveErrors = 3
            let maxWaitTime = 600 // Максимум 10 минут (600 секунд)
            var totalWaitTime = 0
            
            while totalWaitTime < maxWaitTime {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                totalWaitTime += 10
                
                do {
                    let status: ReplicateClient.TrainingResponse
                    do {
                        status = try await replicate.fetchTraining(id: training.id)
                    } catch {
                        // При ошибке "empty data" делаем одну повторную попытку через 2 секунды
                        if consecutiveErrors == 0 {
                            logger.warning("First fetchTraining error for chatId=\(chatId): \(error). Retrying once...")
                            try await Task.sleep(nanoseconds: 2_000_000_000)
                            status = try await replicate.fetchTraining(id: training.id)
                        } else {
                            throw error
                        }
                    }
                    
                    consecutiveErrors = 0 // Сбрасываем счётчик ошибок при успехе
                    
                    if status.status != currentStatus {
                        logger.info("Training status for chatId=\(chatId) changed: \(currentStatus) -> \(status.status)")
                        currentStatus = status.status
                    }
                    switch status.status.lowercased() {
                    case "succeeded":
                        let version = status.output?.version ?? replicate.defaultPredictionVersion
                        let triggerWord = "user\(chatId)" // Сохраняем trigger word для использования в промптах
                        await PhotoSessionManager.shared.setModelVersion(version, for: chatId)
                        await PhotoSessionManager.shared.setTriggerWord(triggerWord, for: chatId)
                        await PhotoSessionManager.shared.setTrainingState(.ready, for: chatId)
                        
                        // Сохраняем модель в базу данных
                        do {
                            let trainingId = await PhotoSessionManager.shared.getTrainingId(for: chatId)
                            let userModel = try await UserModel.query(on: application.db)
                                .filter(\.$chatId == chatId)
                                .first()
                            
                            if let existing = userModel {
                                existing.modelVersion = version
                                existing.triggerWord = triggerWord
                                existing.trainingId = trainingId
                                try await existing.update(on: application.db)
                                logger.info("Updated user model in database for chatId=\(chatId)")
                            } else {
                                let newModel = UserModel(chatId: chatId, modelVersion: version, triggerWord: triggerWord, trainingId: trainingId)
                                try await newModel.save(on: application.db)
                                logger.info("Saved user model to database for chatId=\(chatId)")
                            }
                        } catch {
                            logger.error("Failed to save user model to database for chatId=\(chatId): \(error)")
                        }
                        
                        // Удаляем dataset и исходные фото сразу после успешного обучения
                        // Модель уже сохранена на Replicate, данные больше не нужны
                        await datasetBuilder.deleteDataset(at: dataset.datasetPath)
                        await PhotoSessionManager.shared.setDatasetPath(nil, for: chatId)
                        try? await deleteOriginalPhotos(chatId: chatId, application: application, logger: logger)
                        await PhotoSessionManager.shared.clearPhotos(for: chatId)
                        
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
                } catch {
                    consecutiveErrors += 1
                    if consecutiveErrors >= maxConsecutiveErrors {
                        logger.error("Training status check failed \(consecutiveErrors) times for chatId=\(chatId): \(error)")
                        throw error
                    }
                    // При ошибке ждём немного дольше перед следующим запросом
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    totalWaitTime += 5
                }
            }
            
            logger.error("Training status check timeout for chatId=\(chatId) after \(maxWaitTime) seconds")
            await PhotoSessionManager.shared.setTrainingState(.failed, for: chatId)
            try await sendMessage(token: botToken, chatId: chatId, text: "Обучение модели заняло слишком много времени. Попробуй позже или с другими фото.", application: application)
        } catch {
            logger.error("Training pipeline failed for chatId=\(chatId): \(error)")
            await PhotoSessionManager.shared.setTrainingState(.failed, for: chatId)
            if let datasetPath = await PhotoSessionManager.shared.getDatasetPath(for: chatId) {
                if !keepArtifactsOnFailure {
                    if let datasetBuilder = try? DatasetBuilder(application: application, logger: logger) {
                        await datasetBuilder.deleteDataset(at: datasetPath)
                    }
                } else {
                    logger.warning("Preserving dataset for chatId=\(chatId) due to KEEP_DATASETS_ON_FAILURE flag")
                }
                await PhotoSessionManager.shared.setDatasetPath(nil, for: chatId)
            }
            if keepArtifactsOnFailure {
                logger.warning("Preserving original photos for chatId=\(chatId) due to KEEP_DATASETS_ON_FAILURE flag")
            } else {
                try? await deleteOriginalPhotos(chatId: chatId, application: application, logger: logger)
            }
            try? await sendMessage(token: botToken, chatId: chatId, text: "Что-то пошло не так при обучении модели. Попробуй ещё раз позже.", application: application)
        }
    }

    func generateImages(chatId: Int64, prompt: String, userGender: String? = nil, botToken: String, application: Application, logger: Logger) async {
        guard let modelVersion = await PhotoSessionManager.shared.getModelVersion(for: chatId) else {
            logger.warning("Model version missing for chatId=\(chatId)")
            return
        }

        do {
            let replicate = try ReplicateClient(application: application, logger: logger)
            
            // Получаем выбранный стиль
            let style = await PhotoSessionManager.shared.getStyle(for: chatId) ?? "photo"
            
            // Добавляем стилевые промпты в зависимости от выбора
            let stylePrompts: [String: String] = [
                "cinematic": "cinematic lighting, film photography, professional photography, high quality, detailed, 8k, sharp focus, accurate representation, realistic",
                "anime": "anime style, vibrant colors, detailed illustration, high quality, sharp focus, japanese animation style",
                "cyberpunk": "cyberpunk style, neon lights, futuristic, detailed, high quality, sharp focus, sci-fi atmosphere",
                "photo": "professional photography, high quality, detailed, sharp focus, natural lighting, realistic, accurate representation, photorealistic"
            ]
            
            let stylePrompt = stylePrompts[style] ?? stylePrompts["photo"]!
            
            // Автоматически добавляем trigger word в начало промпта
            let triggerWord = await PhotoSessionManager.shared.getTriggerWord(for: chatId) ?? "user\(chatId)"
            
            // Добавляем указание пола в промпт для лучшего соответствия
            var genderPrompt = ""
            if let gender = userGender {
                genderPrompt = gender == "male" ? ", male person, man" : ", female person, woman"
            }
            
            // Собираем финальный промпт: trigger word + пользовательский промпт + пол + стилевые улучшения
            // Добавляем негативный промпт для лучшего качества
            let negativePrompt = "blurry, low quality, distorted, deformed, bad anatomy, bad proportions, extra limbs, duplicate, watermark, signature, text, ugly, worst quality, low resolution"
            let enhancedPrompt = "\(triggerWord) \(prompt)\(genderPrompt), \(stylePrompt)"
            
            logger.info("Using enhanced prompt for chatId=\(chatId), style=\(style): \(enhancedPrompt)")
            
            try await sendMessage(token: botToken, chatId: chatId, text: "Запускаю генерацию, подожди немного...", application: application)

            // Пытаемся создать prediction с retry при ошибках
            let prediction: ReplicateClient.PredictionResponse
            do {
                prediction = try await replicate.generateImages(modelVersion: modelVersion, prompt: enhancedPrompt, negativePrompt: negativePrompt)
            } catch {
                // При ошибке "empty data" делаем одну повторную попытку
                logger.warning("First generateImages attempt failed for chatId=\(chatId): \(error). Retrying once...")
                try await Task.sleep(nanoseconds: 2_000_000_000)
                prediction = try await replicate.generateImages(modelVersion: modelVersion, prompt: enhancedPrompt, negativePrompt: negativePrompt)
            }
            
            let final = try await replicate.waitForPrediction(id: prediction.id)

            guard final.status.lowercased() == "succeeded", let outputs = final.output else {
                try await sendMessage(token: botToken, chatId: chatId, text: "Не удалось получить изображения. Попробуй сформулировать промпт иначе.", application: application)
                return
            }

            for url in outputs.prefix(4) {
                try await sendPhoto(token: botToken, chatId: chatId, imageURL: url, application: application)
            }

            // Dataset и фото уже удалены после обучения, но проверяем на всякий случай
            if let datasetPath = await PhotoSessionManager.shared.getDatasetPath(for: chatId) {
                let datasetBuilder = try DatasetBuilder(application: application, logger: logger)
                await datasetBuilder.deleteDataset(at: datasetPath)
                await PhotoSessionManager.shared.setDatasetPath(nil, for: chatId)
            }

            await PhotoSessionManager.shared.setTrainingState(.ready, for: chatId)
            await PhotoSessionManager.shared.clearPrompt(for: chatId)

            try await sendMessage(token: botToken, chatId: chatId, text: "Готово! Модель сохранена на нашей стороне. Управлять моделью можно командой /model.", application: application)
        } catch {
            logger.error("Prediction pipeline failed for chatId=\(chatId): \(error)")
            try? await sendMessage(token: botToken, chatId: chatId, text: "Не получилось сгенерировать изображения. Попробуй ещё раз или уточни описание.", application: application)
        }
    }

    func deleteModel(chatId: Int64, botToken: String, application: Application, logger: Logger) async {
        do {
            let replicate = try ReplicateClient(application: application, logger: logger)
            if let version = await PhotoSessionManager.shared.getModelVersion(for: chatId) {
                try await replicate.deleteModelVersion(id: version)
            }
            if let datasetPath = await PhotoSessionManager.shared.getDatasetPath(for: chatId) {
                let datasetBuilder = try DatasetBuilder(application: application, logger: logger)
                await datasetBuilder.deleteDataset(at: datasetPath)
            }
            
            // Удаляем модель из базы данных
            try await UserModel.query(on: application.db)
                .filter(\.$chatId == chatId)
                .delete()
            logger.info("Deleted user model from database for chatId=\(chatId)")
            
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

