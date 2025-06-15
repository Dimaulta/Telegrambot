import Vapor

func routes(_ app: Application) async throws {
    // Базовый маршрут для проверки работоспособности
    app.get { req async throws -> String in
        return "VideoService is running!"
    }
    
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
                
                if let text = message.text {
                    if text == "/start" {
                        // Отправляем приветственное сообщение
                        let botToken = Environment.get("VIDEO_BOT_TOKEN") ?? ""
                        let sendMessageUrl = URI(string: "https://api.telegram.org/bot\(botToken)/sendMessage")
                        let boundary = UUID().uuidString
                        var body = ByteBufferAllocator().buffer(capacity: 0)
                        
                        body.writeString("--\(boundary)\r\n")
                        body.writeString("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n")
                        body.writeString("\(message.chat.id)\r\n")
                        body.writeString("--\(boundary)\r\n")
                        body.writeString("Content-Disposition: form-data; name=\"text\"\r\n\r\n")
                        body.writeString("Привет! Я помогу тебе создать видеокружок. Отправь мне видео, и я обработаю его для тебя.\r\n")
                        body.writeString("--\(boundary)--\r\n")
                        
                        var headers = HTTPHeaders()
                        headers.add(name: "Content-Type", value: "multipart/form-data; boundary=\(boundary)")
                        
                        let response = try await req.client.post(sendMessageUrl, headers: headers) { post in
                            post.body = body
                        }.get()
                        
                        req.logger.info("Ответ на /start отправлен. Статус: \(response.status)")
                        return .ok
                    }
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
                    
                    // Обрабатываем видео
                    let processor = VideoProcessor(req: req)
                    _ = try await processor.downloadAndProcess(videoId: video.file_id, chatId: String(message.chat.id))
                    
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
} 