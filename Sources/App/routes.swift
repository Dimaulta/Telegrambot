import Fluent
import Vapor
import VideoProcessor

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
                let chatId = String(message.chat.id)
                req.logger.info("Получено сообщение от пользователя: \(message.from.first_name) (ID: \(message.from.id))")
                
                if let video = message.video {
                    req.logger.info("Получено видео с ID: \(video.file_id)")
                    req.logger.info("Информация о видео: длительность=\(video.duration), размер=\(video.width)x\(video.height), тип=\(video.mime_type)")

                    do {
                        // Обрабатываем видео с помощью FFmpeg, создаем видеокружок
                        req.logger.info("Начинаем обработку видео...")
                        let response = try await VideoProcessor.downloadAndProcess(fileId: video.file_id, chatId: chatId, req: req).get()
                        req.logger.info("Ответ от Telegram при отправке видео: \(response)")
                        req.logger.info("Видео успешно обработано и отправлено")
                        return .ok
                    } catch {
                        req.logger.error("Ошибка при обработке видео: \(error)")
                        req.logger.error("Детали ошибки: \(String(describing: error))")
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
            req.logger.error("Детали ошибки: \(String(describing: error))")
            return .badRequest
        }
    }

    try app.register(collection: TodoController())
}

// Функция для скачивания видео
func downloadVideo(fileId: String, req: Request) async throws -> URI {
    // Пример запроса для скачивания видео
    let url = URI(string: "https://api.telegram.org/bot\(botToken)/getFile?file_id=\(fileId)")
    let client = req.client
    let response = try await client.get(URI(string: url.string))

    struct TelegramFileResponse: Codable {
        struct Result: Codable {
            let file_path: String
        }
        let result: Result
    }

    let fileResponse = try response.content.decode(TelegramFileResponse.self)
    let path = fileResponse.result.file_path

    let finalUrl = URI(string: "https://api.telegram.org/file/bot\(botToken)/\(path)")
    print("Скачанное видео доступно по URL: \(finalUrl)")
    
    return finalUrl
}

// Функция для отправки видео обратно в Telegram
func sendVideoToTelegram(videoUrl: URI, chatId: String) async throws -> TelegramVideoResponse {
    let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendVideo")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    let bodyData = "chat_id=\(chatId)&video=\(videoUrl.string)"
    request.httpBody = bodyData.data(using: String.Encoding.utf8)

    let (data, _) = try await URLSession.shared.data(for: request)
    let response = try JSONDecoder().decode(TelegramVideoResponse.self, from: data)
    return response
}

// Структура для ответа Telegram при отправке видео
struct TelegramVideoResponse: Codable {
    var fileId: String
}