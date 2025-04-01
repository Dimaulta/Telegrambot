import Fluent
import Vapor

let botToken = "7901916114:AAEAXDcoWhYqq5Wx4TAw1RUaxWxGaXWgf-k"

func routes(_ app: Application) throws {
    // Стартовая проверка
    app.get { req async in
        "It works!"
    }

    app.get("hello") { req async -> String in
        "Hello, world!"
    }

    // Обработка запросов от Telegram по пути /webhook
    app.post("webhook") { req async throws -> HTTPStatus in
        // Логируем сырой запрос для проверки
        let body = req.body.string ?? "Нет тела запроса"
        req.logger.info("Сырой JSON от Telegram: \(body)")
        req.logger.info("Заголовки запроса: \(req.headers)")
        req.logger.info("Метод запроса: \(req.method)")
        req.logger.info("URL запроса: \(req.url)")

        do {
            // Декодируем данные от Telegram
            let update = try req.content.decode(TelegramUpdate.self)
            req.logger.info("Декодированное сообщение: \(update)")

            if let message = update.message {
                _ = String(message.chat.id) // Оставляем для совместимости, хотя не используется
                req.logger.info("Получено сообщение от пользователя: \(message.from.first_name) (ID: \(message.from.id))")

           // Обработка команды /start
if let text = message.text, text == "/start" {
    let sendMessageUrl = URI(string: "https://api.telegram.org/bot\(botToken)/sendMessage")
    let boundary = UUID().uuidString
    var body = ByteBufferAllocator().buffer(capacity: 0)

    body.writeString("--\(boundary)\r\n")
    body.writeString("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n")
    body.writeString("\(message.chat.id)\r\n")
    body.writeString("--\(boundary)\r\n")
    body.writeString("Content-Disposition: form-data; name=\"text\"\r\n\r\n")
    body.writeString("Привет! Отправь мне видео, и я превращу его в видеокружок.\r\n")
    body.writeString("--\(boundary)\r\n")
    body.writeString("Content-Disposition: form-data; name=\"reply_markup\"\r\n\r\n")
    body.writeString("""
    {
        "inline_keyboard": [
            [
                {
                    "text": "Привет!",
                    "callback_data": "greeting"
                }
            ]
        ]
    }
    \r\n
    """)
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
                    req.logger.info("Информация о видео: длительность=\(video.duration), размер=\(video.width)x\(video.height), тип=\(video.mime_type)")

                    // Проверяем длительность видео
                    if video.duration > 60 {
                        req.logger.info("Видео слишком длинное (\(video.duration) секунд), максимум 60 секунд")

                        // Отправляем сообщение об ошибке в чат
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

                    // Проверяем, есть ли username в имени файла видео
                    var targetChatId = String(message.chat.id) // По умолчанию отправляем в тот же чат
                    let fileName = video.file_name ?? "" // Используем пустую строку, если file_name отсутствует
                    req.logger.info("Имя файла видео: \(fileName)")

                    let usernamePattern = "@[a-zA-Z0-9_]+"
                    if let usernameRange = fileName.range(of: usernamePattern, options: .regularExpression) {
                        let username = String(fileName[usernameRange]).dropFirst() // Убираем @

                        // Запрашиваем chatId по username через getChat
                        let getChatUrl = URI(string: "https://api.telegram.org/bot\(botToken)/getChat?chat_id=@\(username)")

                        let chatResponse = try await req.client.get(getChatUrl).flatMapThrowing { res -> (Int64?) in
                            guard res.status == .ok, let body = res.body else {
                                req.logger.error("Не удалось получить chatId для username @\(username): \(res.status)")
                                return nil
                            }
                            let data = body.getData(at: 0, length: body.readableBytes) ?? Data()
                            struct ChatResponse: Content {
                                let ok: Bool
                                let result: Chat?
                            }
                            let response = try JSONDecoder().decode(ChatResponse.self, from: data)
                            return response.result?.id
                        }.get()

                        if let chatId = chatResponse {
                            targetChatId = String(chatId)
                            req.logger.info("Найден chatId для @\(username): \(targetChatId)")

                            // Отправляем уведомление в исходный чат
                            let sendMessageUrl = URI(string: "https://api.telegram.org/bot\(botToken)/sendMessage")
                            let notifyBoundary = UUID().uuidString
                            var notifyBody = ByteBufferAllocator().buffer(capacity: 0)

                            notifyBody.writeString("--\(notifyBoundary)\r\n")
                            notifyBody.writeString("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n")
                            notifyBody.writeString("\(message.chat.id)\r\n")
                            notifyBody.writeString("--\(notifyBoundary)\r\n")
                            notifyBody.writeString("Content-Disposition: form-data; name=\"text\"\r\n\r\n")
                            notifyBody.writeString("Видеокружок отправлен @\(username).\r\n")
                            notifyBody.writeString("--\(notifyBoundary)--\r\n")

                            var notifyHeaders = HTTPHeaders()
                            notifyHeaders.add(name: "Content-Type", value: "multipart/form-data; boundary=\(notifyBoundary)")

                            _ = try await req.client.post(sendMessageUrl, headers: notifyHeaders) { post in
                                post.body = notifyBody
                            }.get()
                        } else {
                            req.logger.warning("Не удалось найти chatId для @\(username), отправляем в исходный чат: \(targetChatId)")

                            // Отправляем сообщение об ошибке в исходный чат
                            let sendMessageUrl = URI(string: "https://api.telegram.org/bot\(botToken)/sendMessage")
                            let errorBoundary = UUID().uuidString
                            var errorBody = ByteBufferAllocator().buffer(capacity: 0)

                            errorBody.writeString("--\(errorBoundary)\r\n")
                            errorBody.writeString("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n")
                            errorBody.writeString("\(message.chat.id)\r\n")
                            errorBody.writeString("--\(errorBoundary)\r\n")
                            errorBody.writeString("Content-Disposition: form-data; name=\"text\"\r\n\r\n")
                            errorBody.writeString("Пользователь @\(username) должен начать взаимодействие со мной, отправив /start.\r\n")
                            errorBody.writeString("--\(errorBoundary)--\r\n")

                            var errorHeaders = HTTPHeaders()
                            errorHeaders.add(name: "Content-Type", value: "multipart/form-data; boundary=\(errorBoundary)")

                            _ = try await req.client.post(sendMessageUrl, headers: errorHeaders) { post in
                                post.body = errorBody
                            }.get()
                        }
                    } else {
                        req.logger.info("Username не найден в имени файла, отправляем в исходный чат: \(targetChatId)")
                    }

                    // Проверяем, не обрабатывается ли уже другое видео
                    req.logger.info("Проверка isProcessing: \(app.isProcessing)")
                    guard !app.isProcessing else {
                        req.logger.warning("Другое видео уже обрабатывается")
                        return .tooManyRequests
                    }

                    app.isProcessing = true
                    req.logger.info("Установлен isProcessing = true")

                    defer {
                        app.isProcessing = false
                        req.logger.info("Обработка завершена, сбрасываем isProcessing")
                    }

                    req.logger.info("Начинаем процесс обработки видео. FileId: \(video.file_id), ChatId: \(targetChatId)")

                    do {
                        // Обрабатываем видео с помощью VideoProcessor
                        let processor = VideoProcessor(botToken: botToken, req: req)
                        try await processor.downloadAndProcess(videoId: video.file_id, chatId: targetChatId)
                        req.logger.info("Видео успешно обработано и отправлено")
                        return .ok
                    } catch {
                        req.logger.error("Ошибка при обработке видео: \(error)")
                        req.logger.error("Детали ошибки: \(error.localizedDescription)")

                        // Отправляем сообщение об ошибке в исходный чат
                        let sendMessageUrl = URI(string: "https://api.telegram.org/bot\(botToken)/sendMessage")
                        let errorBoundary = UUID().uuidString
                        var errorBody = ByteBufferAllocator().buffer(capacity: 0)

                        errorBody.writeString("--\(errorBoundary)\r\n")
                        errorBody.writeString("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n")
                        errorBody.writeString("\(message.chat.id)\r\n")
                        errorBody.writeString("--\(errorBoundary)\r\n")
                        errorBody.writeString("Content-Disposition: form-data; name=\"text\"\r\n\r\n")
                        errorBody.writeString("Произошла ошибка при обработке видео: \(error.localizedDescription)\r\n")
                        errorBody.writeString("--\(errorBoundary)--\r\n")

                        var errorHeaders = HTTPHeaders()
                        errorHeaders.add(name: "Content-Type", value: "multipart/form-data; boundary=\(errorBoundary)")

                        _ = try await req.client.post(sendMessageUrl, headers: errorHeaders) { post in
                            post.body = errorBody
                        }.get()

                        return .internalServerError
                    }
                } else {
                    req.logger.info("Видео не найдено в сообщении")
                    return .badRequest
                }
            } else {
                req.logger.info("Сообщение не найдено в обновлении")
                return .badRequest
            }
        } catch {
            req.logger.error("Ошибка при обработке webhook: \(error)")
            req.logger.error("Детали ошибки: \(error.localizedDescription)")
            return .badRequest
        }
    }

    try app.register(collection: TodoController())
}