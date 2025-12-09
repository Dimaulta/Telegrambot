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

                let incomingText = message.text ?? ""

                // Регистрируем пользователя в общей базе монетизации
                MonetizationService.registerUser(
                    botName: "Roundsvideobot",
                    chatId: message.chat.id,
                    logger: req.logger,
                    env: req.application.environment
                )
                
                // Если пользователь нажал кнопку "Я подписался, проверить" —
                // повторно проверяем подписку и либо разблокируем, либо снова показываем требование.
                if incomingText == "✅ Я подписался, проверить" {
                    let (allowed, channels) = await MonetizationService.checkAccess(
                        botName: "Roundsvideobot",
                        userId: message.from.id,
                        logger: req.logger,
                        env: req.application.environment,
                        client: req.client
                    )

                    let botToken = Environment.get("VIDEO_BOT_TOKEN") ?? ""
                    let sendMessageUrl = URI(string: "https://api.telegram.org/bot\(botToken)/sendMessage")

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

                    if allowed {
                        let text = "Подписка подтверждена ✅\nМожешь отправить видео, и я сделаю из него видеокружок"
                        let keyboard = ReplyKeyboardMarkup(
                            keyboard: [[KeyboardButton(text: "📷 Отправить видео ещё раз")]],
                            resize_keyboard: true,
                            one_time_keyboard: false
                        )
                        let payload = AccessPayloadWithKeyboard(
                            chat_id: message.chat.id,
                            text: text,
                            disable_web_page_preview: false,
                            reply_markup: keyboard
                        )

                        _ = try await req.client.post(sendMessageUrl) { sendReq in
                            try sendReq.content.encode(payload, as: .json)
                        }.get()

                        return .ok
                    } else {
                        let channelsText: String
                        if channels.isEmpty {
                            channelsText = ""
                        } else {
                            let listed = channels.map { "@\($0)" }.joined(separator: "\n")
                            channelsText = "\n\nПодпишись, пожалуйста, на спонсорские каналы:\n\(listed)"
                        }

                        let text = "Я всё ещё не вижу активную подписку.\n\nЧтобы воспользоваться ботом, нужна подписка на спонсорские каналы.\(channelsText)"
                        let keyboard = ReplyKeyboardMarkup(
                            keyboard: [[KeyboardButton(text: "✅ Я подписался, проверить")]],
                            resize_keyboard: true,
                            one_time_keyboard: false
                        )
                        let payload = AccessPayloadWithKeyboard(
                            chat_id: message.chat.id,
                            text: text,
                            disable_web_page_preview: false,
                            reply_markup: keyboard
                        )

                        _ = try await req.client.post(sendMessageUrl) { sendReq in
                            try sendReq.content.encode(payload, as: .json)
                        }.get()

                        return .ok
                    }
                }

                // Обычная проверка доступа по спонсорской подписке
                let (allowed, channels) = await MonetizationService.checkAccess(
                    botName: "Roundsvideobot",
                    userId: message.from.id,
                    logger: req.logger,
                    env: req.application.environment,
                    client: req.client
                )

                if !allowed {
                    let botToken = Environment.get("VIDEO_BOT_TOKEN") ?? ""
                    let sendMessageUrl = URI(string: "https://api.telegram.org/bot\(botToken)/sendMessage")

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
                        chat_id: message.chat.id,
                        text: text,
                        disable_web_page_preview: false,
                        reply_markup: keyboard
                    )

                    _ = try await req.client.post(sendMessageUrl) { sendReq in
                        try sendReq.content.encode(payload, as: .json)
                    }.get()

                    req.logger.info("Доступ для пользователя \(message.from.id) ограничен спонсорской подпиской.")
                    return .ok
                }
                
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
                    // Лимит: не более 2 видео в минуту на пользователя
                    let chatIdStr = String(message.chat.id)
                    if await !RateLimiter.shared.allow(key: chatIdStr) {
                        let botToken = Environment.get("VIDEO_BOT_TOKEN") ?? ""
                        let sendMessageUrl = URI(string: "https://api.telegram.org/bot\(botToken)/sendMessage")
                        let boundary = UUID().uuidString
                        var body = ByteBufferAllocator().buffer(capacity: 0)
                        
                        body.writeString("--\(boundary)\r\n")
                        body.writeString("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n")
                        body.writeString("\(message.chat.id)\r\n")
                        body.writeString("--\(boundary)\r\n")
                        body.writeString("Content-Disposition: form-data; name=\"text\"\r\n\r\n")
                        body.writeString("Подождите 1 минуту\r\n")
                        body.writeString("--\(boundary)--\r\n")
                        
                        var headers = HTTPHeaders()
                        headers.add(name: "Content-Type", value: "multipart/form-data; boundary=\(boundary)")
                        
                        _ = try await req.client.post(sendMessageUrl, headers: headers) { post in
                            post.body = body
                        }.get()
                        
                        req.logger.info("Превышен лимит отправок для чата \(chatIdStr). Сообщение об ожидании отправлено.")
                        return .ok
                    }
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
    app.post(["api", "upload"]) { req async throws -> Response in
        struct UploadData: Content {
            var video: File
            var chatId: String
            var cropData: String
        }

        let upload = try req.content.decode(UploadData.self)
        let file = upload.video
        let chatId = upload.chatId
        req.logger.info("Получен файл: \(file.filename), размер: \(file.data.readableBytes) байт")
        
        // Лимит: не более 2 видео в минуту на пользователя
        if await !RateLimiter.shared.allow(key: chatId) {
            let botToken = Environment.get("VIDEO_BOT_TOKEN") ?? ""
            let sendMessageUrl = URI(string: "https://api.telegram.org/bot\(botToken)/sendMessage")
            let boundary = UUID().uuidString
            var body = ByteBufferAllocator().buffer(capacity: 0)
            
            body.writeString("--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n")
            body.writeString("\(chatId)\r\n")
            body.writeString("--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"text\"\r\n\r\n")
            body.writeString("Подождите 1 минуту\r\n")
            body.writeString("--\(boundary)--\r\n")
            
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "multipart/form-data; boundary=\(boundary)")
            
            _ = try await req.client.post(sendMessageUrl, headers: headers) { post in
                post.body = body
            }.get()
            
            var resp = Response(status: .tooManyRequests)
            resp.body = .init(string: "Подождите 1 минуту")
            return resp
        }

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

        var okResp = Response(status: .ok)
        okResp.body = .init(string: "Видео успешно обработано и отправлено!")
        return okResp
    }
    
    // Отдаём index.html при GET //
    app.get { req async throws -> Response in
        let filePath = app.directory.publicDirectory + "index.html"
        return req.fileio.streamFile(at: filePath)
    }
} 