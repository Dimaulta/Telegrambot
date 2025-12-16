import Vapor
import Fluent

func routes(_ app: Application) throws {
    let controller = NeurfotobotController()
    // Подавляем предупреждения Sendable - контроллер безопасен для использования в async контексте
    app.post("webhook") { req async throws -> Response in
        try await controller.handleWebhook(req)
    }
    // Дополнительный путь для проксирования через nginx/балансировщик
    app.post("neurfoto", "webhook") { req async throws -> Response in
        try await controller.handleWebhook(req)
    }
    app.get("health") { _ in
        "ok"
    }

    // Отдача локального датасета для Replicate через BASE_URL
    app.get("neurfotobot", "datasets", ":chatId", "dataset.zip") { req async throws -> Response in
        guard let chatIdParam = req.parameters.get("chatId"),
              let chatId = Int64(chatIdParam) else {
            throw Abort(.badRequest, reason: "Invalid chatId")
        }

        let relativePath = "datasets/\(chatId)/dataset.zip"
        let fileURL = try NeurfotobotTempDirectory.fileURL(relativePath: relativePath)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw Abort(.notFound, reason: "Dataset not found for chatId=\(chatId)")
        }

        let data = try Data(contentsOf: fileURL)
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/zip")

        return Response(status: .ok, headers: headers, body: .init(buffer: buffer))
    }
    
    // Временный роут для добавления записи модели в БД (удалить после использования)
    app.post("admin", "add-model") { req async throws -> String in
        struct AddModelRequest: Content {
            let chatId: Int64
            let modelVersion: String?
            let trainingId: String?
            let triggerWord: String?
        }
        
        let request = try req.content.decode(AddModelRequest.self)
        let chatId = request.chatId
        let triggerWord = request.triggerWord ?? "user\(chatId)"
        
        // Если версия не указана, пытаемся получить из training ID или найти последнюю версию на Replicate
        var modelVersion = request.modelVersion
        
        if modelVersion == nil {
            do {
                let replicate = try ReplicateClient(application: req.application, logger: req.logger)
                
                // Если есть training ID, получаем версию из него
                if let trainingId = request.trainingId {
                    let training = try await replicate.fetchTraining(id: trainingId)
                    if let version = training.output?.version {
                        modelVersion = version
                        req.logger.info("Got model version \(version) from training \(trainingId)")
                    }
                }
                
                // Если всё ещё нет версии, пытаемся найти последнюю версию
                if modelVersion == nil {
                    if let foundVersion = try? await replicate.findModelVersion(for: chatId) {
                        modelVersion = foundVersion
                        req.logger.info("Found model version \(foundVersion) for chatId=\(chatId) on Replicate")
                    }
                }
            } catch {
                req.logger.warning("Failed to find model version from Replicate: \(error)")
            }
        }
        
        guard let version = modelVersion else {
            throw Abort(.badRequest, reason: "Model version is required. Provide modelVersion or trainingId in request body.")
        }
        
        // Проверяем, есть ли уже запись
        if let existing = try await UserModel.query(on: req.db)
            .filter(\.$chatId == chatId)
            .first() {
            existing.modelVersion = version
            existing.triggerWord = triggerWord
            existing.trainingId = request.trainingId
            try await existing.update(on: req.db)
            return "Updated existing model for chatId=\(chatId), version=\(version), triggerWord=\(triggerWord)"
        } else {
            let userModel = UserModel(chatId: chatId, modelVersion: version, triggerWord: triggerWord, trainingId: request.trainingId)
            try await userModel.save(on: req.db)
            return "Created model record for chatId=\(chatId), version=\(version), triggerWord=\(triggerWord)"
        }
    }
} 