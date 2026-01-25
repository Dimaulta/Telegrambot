import Vapor

func routes(_ app: Application) async throws {
    // Базовый маршрут для проверки работоспособности
    // app.get { req async throws -> String in
    //     return "VideoService is running!"
    // }
    
    // Маршрут для обработки webhook'а от Telegram
    // Поддерживаем оба варианта: /webhook и /rounds/webhook (для Traefik)
    app.post("webhook") { req async throws -> HTTPStatus in
        return try await handleWebhook(req: req)
    }
    app.post("rounds", "webhook") { req async throws -> HTTPStatus in
        return try await handleWebhook(req: req)
    }
    
    // Вспомогательная функция для обработки webhook
    @Sendable
    func handleWebhook(req: Request) async throws -> HTTPStatus {
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
                            chat_id: message.chat.id,
                            text: "Подписка подтверждена ✅",
                            disable_web_page_preview: false,
                            reply_markup: removeKeyboard
                        )
                        
                        _ = try await req.client.post(sendMessageUrl) { sendReq in
                            try sendReq.content.encode(removePayload, as: .json)
                        }.get()
                        
                        // Проверяем, есть ли сохраненное видео для автоматической обработки
                        if let savedVideo = await VideoSessionManager.shared.getVideo(userId: message.from.id) {
                            // Есть сохраненное видео - автоматически обрабатываем его
                            await VideoSessionManager.shared.clearVideo(userId: message.from.id)
                            
                            req.logger.info("✅ Subscription confirmed, processing saved video file_id: \(savedVideo.fileId)")
                            
                            // Обрабатываем сохраненное видео
                            do {
                                try await processVideoByFileId(
                                    fileId: savedVideo.fileId,
                                    duration: savedVideo.duration,
                                    chatId: message.chat.id,
                                    req: req
                                )
                            } catch {
                                req.logger.error("❌ Error processing saved video: \(error)")
                                let errorPayload = AccessPayloadWithKeyboard(
                                    chat_id: message.chat.id,
                                    text: "😔 Произошла ошибка при обработке видео. Попробуй отправить видео ещё раз.",
                                    disable_web_page_preview: false,
                                    reply_markup: nil
                                )
                                _ = try? await req.client.post(sendMessageUrl) { sendReq in
                                    try sendReq.content.encode(errorPayload, as: .json)
                                }.get()
                            }
                            
                            return .ok
                        } else {
                            // Нет сохраненного видео - отправляем обычное сообщение
                            let text = "Можешь отправить видео, и я сделаю из него видеокружок"
                            let payload = AccessPayloadWithKeyboard(
                                chat_id: message.chat.id,
                                text: text,
                                disable_web_page_preview: false,
                                reply_markup: nil
                            )

                            _ = try await req.client.post(sendMessageUrl) { sendReq in
                                try sendReq.content.encode(payload, as: .json)
                            }.get()

                            return .ok
                        }
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

                // Важно: Проверку подписки переносим на момент, когда пользователь отправляет видео
                
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

                // Обработка видео (здесь выполняем проверку подписки)
                if let video = message.video {
                    // Проверка доступа по спонсорской подписке прямо перед обработкой видео
                    do {
                        let (allowed, channels) = await MonetizationService.checkAccess(
                            botName: "Roundsvideobot",
                            userId: message.from.id,
                            logger: req.logger,
                            env: req.application.environment,
                            client: req.client
                        )
                        if !allowed {
                            // Сохраняем file_id и длительность видео перед отправкой сообщения о подписке
                            await VideoSessionManager.shared.saveVideo(userId: message.from.id, fileId: video.file_id, duration: video.duration)
                            
                            let botToken = Environment.get("VIDEO_BOT_TOKEN") ?? ""
                            let sendMessageUrl = URI(string: "https://api.telegram.org/bot\(botToken)/sendMessage")

                            struct KeyboardButton: Content { let text: String }
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

                            req.logger.info("Доступ для пользователя \(message.from.id) ограничен спонсорской подпиской (перед обработкой видео). File_id сохранен: \(video.file_id)")
                            return .ok
                        }
                    }
                    
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
    // Поддерживаем оба варианта: /api/upload и /rounds/api/upload (для Traefik)
    app.post(["api", "upload"]) { req async throws -> Response in
        return try await handleUpload(req: req)
    }
    app.post(["rounds", "api", "upload"]) { req async throws -> Response in
        return try await handleUpload(req: req)
    }
    
    // Вспомогательная функция для обработки загрузки
    @Sendable
    func handleUpload(req: Request) async throws -> Response {
        req.logger.info("Получен запрос на /api/upload")
        req.logger.info("Content-Type: \(req.headers.first(name: .contentType) ?? "не указан")")
        req.logger.info("Content-Length: \(req.headers.first(name: .contentLength) ?? "не указан")")
        req.logger.info("Все заголовки: \(req.headers)")
        
        // Собираем тело запроса полностью
        guard let body = req.body.data else {
            req.logger.error("Тело запроса пустое")
            throw Abort(.badRequest, reason: "Тело запроса пустое")
        }
        
        req.logger.info("Размер тела запроса: \(body.readableBytes) байт")
        
        struct UploadData: Content {
            var video: File
            var chatId: String
            var cropData: String
        }

        do {
            // Пробуем декодировать multipart/form-data
            let upload = try req.content.decode(UploadData.self)
            let file = upload.video
            let chatId = upload.chatId
            req.logger.info("Получен файл: \(file.filename), размер: \(file.data.readableBytes) байт")
            
            // Проверка подписки перед обработкой из мини-аппы
            if let userId = Int64(chatId) {
            let (allowed, channels) = await MonetizationService.checkAccess(
                botName: "Roundsvideobot",
                userId: userId,
                logger: req.logger,
                env: req.application.environment,
                client: req.client
            )
            if !allowed {
                let botToken = Environment.get("VIDEO_BOT_TOKEN") ?? ""
                let sendMessageUrl = URI(string: "https://api.telegram.org/bot\(botToken)/sendMessage")
                
                struct KeyboardButton: Content { let text: String }
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
                    chat_id: userId,
                    text: text,
                    disable_web_page_preview: false,
                    reply_markup: keyboard
                )
                
                _ = try await req.client.post(sendMessageUrl) { sendReq in
                    try sendReq.content.encode(payload, as: .json)
                }.get()
                
                let resp = Response(status: .forbidden)
                resp.body = .init(string: "Требуется подписка на спонсорские каналы")
                return resp
            }
            }
            
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
            
                let resp = Response(status: .tooManyRequests)
                resp.body = .init(string: "Подождите 1 минуту")
                return resp
            }

            // Декодируем cropData
            req.logger.info("Сырой cropData строка: \(upload.cropData)")
            req.logger.info("Длина cropData: \(upload.cropData.count) символов")
            
            guard let cropDataJson = upload.cropData.data(using: .utf8) else {
                req.logger.error("Не удалось преобразовать cropData в Data")
                throw Abort(.badRequest, reason: "Некорректный формат cropData")
            }
            
            req.logger.info("CropData JSON bytes: \(cropDataJson.count) байт")
            
            let cropData: CropData
            do {
                cropData = try JSONDecoder().decode(CropData.self, from: cropDataJson)
                req.logger.info("CropData успешно декодирован: x=\(cropData.x), y=\(cropData.y), w=\(cropData.width), h=\(cropData.height), scale=\(cropData.scale)")
            } catch {
                req.logger.error("Ошибка декодирования CropData: \(error)")
                if let jsonString = String(data: cropDataJson, encoding: .utf8) {
                    req.logger.error("Попытка декодировать JSON: \(jsonString)")
                }
                throw Abort(.badRequest, reason: "Некорректный формат cropData: \(error.localizedDescription)")
            }

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

            let okResp = Response(status: .ok)
            okResp.body = .init(string: "Видео успешно обработано и отправлено!")
            return okResp
        } catch {
            req.logger.error("Ошибка при обработке загрузки: \(error)")
            req.logger.error("Детали ошибки: \(error.localizedDescription)")
            
            // Если ошибка декодирования, пробуем прочитать сырые данные
            if error.localizedDescription.contains("content type") || error.localizedDescription.contains("decode") || error.localizedDescription.contains("Can't decode") {
                req.logger.error("Проблема с декодированием multipart/form-data")
                req.logger.error("Попытка прочитать сырые данные...")
                
                // Логируем первые 500 байт тела запроса для отладки
                if let bodyData = req.body.data {
                    let previewSize = min(500, bodyData.readableBytes)
                    if let preview = bodyData.getData(at: 0, length: previewSize) {
                        if let previewString = String(data: preview, encoding: .utf8) {
                            req.logger.error("Начало тела запроса (первые \(previewSize) байт): \(previewString)")
                        } else {
                            req.logger.error("Начало тела запроса (первые \(previewSize) байт, не UTF-8): \(preview.count) байт")
                        }
                    }
                }
            }
            
            let errorResp = Response(status: .badRequest)
            var headers = HTTPHeaders()
            headers.add(name: .contentType, value: "text/plain; charset=utf-8")
            errorResp.headers = headers
            
            // Обрезаем сообщение об ошибке до разумной длины
            let errorMsg = error.localizedDescription
            let shortMsg = errorMsg.count > 200 ? String(errorMsg.prefix(197)) + "..." : errorMsg
            errorResp.body = .init(string: "Ошибка при обработке видео: \(shortMsg)")
            
            req.logger.error("Возвращаем ошибку клиенту: \(shortMsg)")
            return errorResp
        }
    }
    
    // Endpoint для логирования с фронтенда
    app.post("api", "log") { req async throws -> HTTPStatus in
        if let body = req.body.string {
            req.logger.info("📱 [FRONTEND LOG] \(body)")
        }
        return .ok
    }
    
    // Отдаём index.html при GET //
    app.get { req async throws -> Response in
        let filePath = app.directory.publicDirectory + "index.html"
        req.logger.info("Запрос index.html, путь: \(filePath)")
        
        // Проверяем существование файла
        guard FileManager.default.fileExists(atPath: filePath) else {
            req.logger.error("Файл index.html не найден по пути: \(filePath)")
            throw Abort(.notFound, reason: "index.html not found")
        }
        
        // Читаем файл и возвращаем Response
        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "text/html; charset=utf-8")
        
        return Response(status: .ok, headers: headers, body: .init(buffer: buffer))
    }
}

/// Обрабатывает видео по file_id (используется после успешной проверки подписки)
func processVideoByFileId(fileId: String, duration: Int, chatId: Int64, req: Request) async throws {
    // Проверяем длительность видео
    if duration > 60 {
        req.logger.info("Видео слишком длинное (\(duration) секунд), максимум 60 секунд")
        
        let botToken = Environment.get("VIDEO_BOT_TOKEN") ?? ""
        let sendMessageUrl = URI(string: "https://api.telegram.org/bot\(botToken)/sendMessage")
        let errorBoundary = UUID().uuidString
        var errorBody = ByteBufferAllocator().buffer(capacity: 0)
        
        errorBody.writeString("--\(errorBoundary)\r\n")
        errorBody.writeString("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n")
        errorBody.writeString("\(chatId)\r\n")
        errorBody.writeString("--\(errorBoundary)\r\n")
        errorBody.writeString("Content-Disposition: form-data; name=\"text\"\r\n\r\n")
        errorBody.writeString("Видео слишком длинное (\(duration) секунд). Максимальная длительность для видеокружка — 60 секунд.\r\n")
        errorBody.writeString("--\(errorBoundary)--\r\n")
        
        var errorHeaders = HTTPHeaders()
        errorHeaders.add(name: "Content-Type", value: "multipart/form-data; boundary=\(errorBoundary)")
        
        _ = try await req.client.post(sendMessageUrl, headers: errorHeaders) { post in
            post.body = errorBody
        }.get()
        
        throw Abort(.badRequest, reason: "Видео слишком длинное")
    }
    
    // Проверяем rate limit
    let chatIdStr = String(chatId)
    if await !RateLimiter.shared.allow(key: chatIdStr) {
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
        
        req.logger.info("Превышен лимит отправок для чата \(chatIdStr). Сообщение об ожидании отправлено.")
        return
    }
    
    req.logger.info("Обрабатываем сохраненное видео с file_id: \(fileId)")
    
    // Получаем информацию о файле
    let getFileUrl = URI(string: "https://api.telegram.org/bot\(Environment.get("VIDEO_BOT_TOKEN") ?? "")/getFile?file_id=\(fileId)")
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
    statusBody.writeString("\(chatId)\r\n")
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
    try await processor.processAndSendCircleVideo(inputPath: inputUrl.path, chatId: String(chatId))
    
    // Удаляем входной файл
    try? FileManager.default.removeItem(at: inputUrl)
} 