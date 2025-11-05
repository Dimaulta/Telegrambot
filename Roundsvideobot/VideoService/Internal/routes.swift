import Vapor

func routes(_ app: Application) async throws {
    // Базовый маршрут для проверки работоспособности
    // app.get { req async throws -> String in
    //     return "VideoService is running!"
    // }
    
    // Маршрут для обработки webhook'а от Telegram
    app.post("webhook") { req async throws -> HTTPStatus in
        // Логируем сырой запрос для проверки
        let body = req.body.string ?? "Нет тела запроса"
        req.logger.info("Сырой JSON от Telegram: \(body)")
        
        do {
            // Декодируем данные от Telegram
            let update = try req.content.decode(TelegramUpdate.self)
            req.logger.info("Декодированное сообщение: \(update)")
            
            if let message = update.message {
                req.logger.info("Получено сообщение от пользователя: \(message.from.first_name) (ID: \(message.from.id))")

                // Обрабатываем /start отдельно
                if let text = message.text, text == "/start" {
                    let botToken = Environment.get("VIDEO_BOT_TOKEN") ?? ""
                    let sendMessageUrl = URI(string: "https://api.telegram.org/bot\(botToken)/sendMessage")
                    let boundary = UUID().uuidString
                    var body = ByteBufferAllocator().buffer(capacity: 0)

                    body.writeString("--\(boundary)\r\n")
                    body.writeString("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n")
                    body.writeString("\(message.chat.id)\r\n")
                    body.writeString("--\(boundary)\r\n")
                    body.writeString("Content-Disposition: form-data; name=\"text\"\r\n\r\n")
                    body.writeString("Привет! Я помогу тебе создать видеокружок. Отправь мне обычное видео до 60 секунд, и я обработаю его для тебя.\r\n")
                    body.writeString("--\(boundary)--\r\n")

                    var headers = HTTPHeaders()
                    headers.add(name: "Content-Type", value: "multipart/form-data; boundary=\(boundary)")

                    let response = try await req.client.post(sendMessageUrl, headers: headers) { post in
                        post.body = body
                    }.get()

                    req.logger.info("Ответ на /start отправлен. Статус: \(response.status)")
                    return .ok
                }

                // Обработка видео
                if let video = message.video {
                    req.logger.info("Получено видео с ID: \(video.file_id)")
                    
                    // Проверяем длительность видео
                    if video.duration > 60 {
                        req.logger.info("Видео слишком длинное (\(video.duration) секунд), максимум 60 секунд")
                        
                        // Отправляем сообщение об ошибке
                        let botToken = Environment.get("VIDEO_BOT_TOKEN") ?? ""
                        let sendMessageUrl = URI(string: "https://api.telegram.org/bot\(botToken)/sendMessage")
                        let errorBoundary = UUID().uuidString
                        var errorBody = ByteBufferAllocator().buffer(capacity: 0)
                        
                        errorBody.writeString("--\(errorBoundary)\r\n")
                        errorBody.writeString("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n")
                        errorBody.writeString("\(message.chat.id)\r\n")
                        errorBody.writeString("--\(errorBoundary)\r\n")
                        errorBody.writeString("Content-Disposition: form-data; name=\"text\"\r\n\r\n")
                        errorBody.writeString("Видео слишком длинное (\(video.duration) секунд). Максимальная длительность для видеокружка — 60 секунд.\r\n")
                        errorBody.writeString("--\(errorBoundary)--\r\n")
                        
                        var errorHeaders = HTTPHeaders()
                        errorHeaders.add(name: "Content-Type", value: "multipart/form-data; boundary=\(errorBoundary)")
                        
                        _ = try await req.client.post(sendMessageUrl, headers: errorHeaders) { post in
                            post.body = errorBody
                        }.get()
                        
                        return .badRequest
                    }
                    
                    // Получаем информацию о файле
                    let getFileUrl = URI(string: "https://api.telegram.org/bot\(Environment.get("VIDEO_BOT_TOKEN") ?? "")/getFile?file_id=\(video.file_id)")
                    let fileResponse = try await req.client.get(getFileUrl).flatMapThrowing { res -> TelegramFileResponse in
                        guard res.status == HTTPStatus.ok, let body = res.body else {
                            throw Abort(.badRequest, reason: "Не удалось получить информацию о файле")
                        }
                        let data = body.getData(at: 0, length: body.readableBytes) ?? Data()
                        return try JSONDecoder().decode(TelegramFileResponse.self, from: data)
                    }.get()

                    let filePath = fileResponse.result.file_path
                    let downloadUrl = URI(string: "https://api.telegram.org/file/bot\(Environment.get("VIDEO_BOT_TOKEN") ?? "")/\(filePath)")
                    
                    // Скачиваем видео
                    let downloadResponse = try await req.client.get(downloadUrl).get()
                    guard downloadResponse.status == HTTPStatus.ok, let body = downloadResponse.body else {
                        throw Abort(.badRequest, reason: "Не удалось скачать видео")
                    }

                    let videoData = body.getData(at: 0, length: body.readableBytes) ?? Data()
                    let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                    let uniqueId = UUID().uuidString.prefix(8)
                    let inputFileName = "input_\(timestamp)_\(uniqueId).mp4"
                    let inputUrl = URL(fileURLWithPath: "Roundsvideobot/Resources/temporaryvideoFiles/").appendingPathComponent(inputFileName)
                    
                    try videoData.write(to: inputUrl)
                    
                    // Отправляем сообщение "Видео получено, ожидайте..."
                    let botToken = Environment.get("VIDEO_BOT_TOKEN") ?? ""
                    let statusMessageUrl = URI(string: "https://api.telegram.org/bot\(botToken)/sendMessage")
                    let statusBoundary = UUID().uuidString
                    var statusBody = ByteBufferAllocator().buffer(capacity: 0)
                    
                    statusBody.writeString("--\(statusBoundary)\r\n")
                    statusBody.writeString("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n")
                    statusBody.writeString("\(message.chat.id)\r\n")
                    statusBody.writeString("--\(statusBoundary)\r\n")
                    statusBody.writeString("Content-Disposition: form-data; name=\"text\"\r\n\r\n")
                    statusBody.writeString("🎬 Видео получено, ожидайте...\r\n")
                    statusBody.writeString("--\(statusBoundary)--\r\n")
                    
                    var statusHeaders = HTTPHeaders()
                    statusHeaders.add(name: "Content-Type", value: "multipart/form-data; boundary=\(statusBoundary)")
                    
                    _ = try await req.client.post(statusMessageUrl, headers: statusHeaders) { post in
                        post.body = statusBody
                    }.get()
                    
                    // Обрабатываем видео и отправляем кружочек
                    let processor = VideoProcessor(req: req)
                    try await processor.processAndSendCircleVideo(inputPath: inputUrl.path, chatId: String(message.chat.id))
                    
                    // Удаляем входной файл
                    try? FileManager.default.removeItem(at: inputUrl)
                    
                    return .ok
                } else {
                    // Любой другой контент (текст, фото, video_note и т.п.)
                    let botToken = Environment.get("VIDEO_BOT_TOKEN") ?? ""
                    let sendMessageUrl = URI(string: "https://api.telegram.org/bot\(botToken)/sendMessage")
                    let boundary = UUID().uuidString
                    var body = ByteBufferAllocator().buffer(capacity: 0)

                    body.writeString("--\(boundary)\r\n")
                    body.writeString("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n")
                    body.writeString("\(message.chat.id)\r\n")
                    body.writeString("--\(boundary)\r\n")
                    body.writeString("Content-Disposition: form-data; name=\"text\"\r\n\r\n")
                    body.writeString("Пришлите обычное видео\r\n")
                    body.writeString("--\(boundary)--\r\n")

                    var headers = HTTPHeaders()
                    headers.add(name: "Content-Type", value: "multipart/form-data; boundary=\(boundary)")

                    _ = try await req.client.post(sendMessageUrl, headers: headers) { post in
                        post.body = body
                    }.get()

                    return .ok
                }
            }
            
            return .ok
        } catch {
            req.logger.error("Ошибка при обработке webhook: \(error)")
            return .badRequest
        }
    }
    
    // Маршрут для обработки видео
    app.post("process-video") { req async throws -> String in
        guard req.body.data != nil else {
            throw Abort(.badRequest, reason: "No video data provided")
        }
        
        // Здесь будет логика обработки видео
        return "Video processing started"
    }
    
    // Маршрут для проверки статуса обработки
    app.get("status", ":id") { req async throws -> String in
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "No processing ID provided")
        }
        
        // Здесь будет логика проверки статуса
        return "Processing status for ID: \(id)"
    }
    
    // Обработчик загрузки видео из мини-аппы
    app.post(["api", "upload"]) { req async throws -> String in
        struct UploadData: Content {
            var video: File
            var chatId: String
            var cropData: String
        }

        let upload = try req.content.decode(UploadData.self)
        let file = upload.video
        let chatId = upload.chatId
        req.logger.info("Получен файл: \(file.filename), размер: \(file.data.readableBytes) байт")

        // Декодируем cropData
        guard let cropDataJson = upload.cropData.data(using: .utf8) else {
            throw Abort(.badRequest, reason: "Некорректный формат cropData")
        }
        let cropData = try JSONDecoder().decode(CropData.self, from: cropDataJson)
        req.logger.info("CropData получен: x=\(cropData.x), y=\(cropData.y), w=\(cropData.width), h=\(cropData.height), scale=\(cropData.scale)")

        // Сохраняем файл во временную директорию
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let uniqueId = UUID().uuidString.prefix(8)
        let inputFileName = "input_\(timestamp)_\(uniqueId).mp4"
        let inputUrl = URL(fileURLWithPath: "Roundsvideobot/Resources/temporaryvideoFiles/").appendingPathComponent(inputFileName)

        let savedData = Data(buffer: file.data)
        try savedData.write(to: inputUrl)

        // Обрабатываем видео с учетом кропа
        let processor = VideoProcessor(req: req)
        let processedUrl = try await processor.processUploadedVideo(filePath: inputUrl.path, cropData: cropData)

        // Готовим и отправляем видеокружок
        let sendVideoUrl = URI(string: "https://api.telegram.org/bot\(Environment.get("VIDEO_BOT_TOKEN") ?? "")/sendVideoNote")
        let boundary = UUID().uuidString
        var body = ByteBufferAllocator().buffer(capacity: 0)

        // chat_id
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n")
        body.writeString("\(chatId)\r\n")

        // video_note
        let processedData = try Data(contentsOf: processedUrl)
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"video_note\"; filename=\"video.mp4\"\r\n")
        body.writeString("Content-Type: video/mp4\r\n\r\n")
        body.writeBytes(processedData)
        body.writeString("\r\n")
        body.writeString("--\(boundary)--\r\n")

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "multipart/form-data; boundary=\(boundary)")

        let response = try await req.client.post(sendVideoUrl, headers: headers) { post in
            post.body = body
        }.get()

        // Чистим временные файлы
        try? FileManager.default.removeItem(at: inputUrl)
        try? FileManager.default.removeItem(at: processedUrl)

        guard response.status == .ok else {
            if let respBody = response.body {
                let respData = respBody.getData(at: 0, length: respBody.readableBytes) ?? Data()
                if let text = String(data: respData, encoding: .utf8) {
                    throw Abort(.badRequest, reason: "Ошибка при отправке видео: \(text)")
                }
            }
            throw Abort(.badRequest, reason: "Не удалось отправить видеокружок")
        }

        return "Видео успешно обработано и отправлено!"
    }
    
    // Отдаём index.html при GET //
    app.get { req async throws -> Response in
        let filePath = app.directory.publicDirectory + "index.html"
        return req.fileio.streamFile(at: filePath)
    }
} 