import Vapor
import Foundation

/// Сервис для работы с Telegram Bot API
struct TelegramService {
    
    // MARK: - Отправка сообщений
    
    static func sendMessage(
        token: String,
        chatId: Int64,
        text: String,
        client: Client,
        replyToMessageId: Int? = nil
    ) async throws -> Int? {
        let payload = TelegramSendMessageRequest(chat_id: chatId, text: text, reply_to_message_id: replyToMessageId)
        let response = try await client.post("https://api.telegram.org/bot\(token)/sendMessage") { request in
            try request.content.encode(payload, as: .json)
        }
        
        // Пытаемся получить message_id из ответа
        if response.status == .ok,
           let body = response.body,
           let bodyString = body.getString(at: 0, length: body.readableBytes, encoding: .utf8),
           let data = bodyString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = json["result"] as? [String: Any],
           let messageId = result["message_id"] as? Int {
            return messageId
        }
        return nil
    }
    
    static func sendMessageWithKeyboard(
        token: String,
        chatId: Int64,
        text: String,
        keyboard: InlineKeyboardMarkup,
        client: Client,
        replyToMessageId: Int? = nil
    ) async throws -> Int? {
        let payload = TelegramSendMessageWithKeyboardRequest(chat_id: chatId, text: text, reply_markup: keyboard, reply_to_message_id: replyToMessageId)
        let response = try await client.post("https://api.telegram.org/bot\(token)/sendMessage") { request in
            try request.content.encode(payload, as: .json)
        }
        
        // Пытаемся получить message_id из ответа
        if response.status == .ok,
           let body = response.body,
           let bodyString = body.getString(at: 0, length: body.readableBytes, encoding: .utf8),
           let data = bodyString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = json["result"] as? [String: Any],
           let messageId = result["message_id"] as? Int {
            return messageId
        }
        return nil
    }
    
    static func answerCallbackQuery(
        token: String,
        callbackId: String,
        text: String?,
        req: Request
    ) async throws {
        let payload = TelegramAnswerCallbackQueryRequest(callback_query_id: callbackId, text: text, show_alert: false)
        _ = try await req.client.post("https://api.telegram.org/bot\(token)/answerCallbackQuery") { request in
            try request.content.encode(payload, as: .json)
        }
    }
    
    static func sendScheduledMessage(
        token: String,
        chatId: Int64,
        text: String,
        scheduleDate: Int,
        req: Request
    ) async throws -> ClientResponse {
        // Telegram API требует schedule_date в Unix timestamp (секунды)
        // Минимальная задержка - 60 секунд от текущего времени
        // Для каналов бот должен быть администратором с правом публикации
        
        // Создаем JSON вручную, чтобы убедиться, что schedule_date передается правильно
        let json: [String: Any] = [
            "chat_id": chatId,
            "text": text,
            "schedule_date": scheduleDate
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: json)
        var buffer = ByteBufferAllocator().buffer(capacity: jsonData.count)
        buffer.writeBytes(jsonData)
        
        req.logger.info("📤 Sending scheduled message to chat \(chatId) with schedule_date: \(scheduleDate) (Unix timestamp)")
        
        var request = ClientRequest(method: .POST, url: URI(string: "https://api.telegram.org/bot\(token)/sendMessage"))
        request.headers.contentType = .json
        request.body = .init(buffer: buffer)
        
        return try await req.client.send(request)
    }
    
    /// Отправить фото с подписью в отложенные публикации
    /// - Parameters:
    ///   - photo: Может быть URL (String), file_id (String) или путь к локальному файлу
    ///   - isLocalFile: Если true, photo - это путь к локальному файлу, нужно отправить через multipart/form-data
    static func sendScheduledPhoto(
        token: String,
        chatId: Int64,
        photo: String,  // URL, file_id или путь к локальному файлу
        caption: String,
        scheduleDate: Int,
        req: Request,
        isLocalFile: Bool = false
    ) async throws -> ClientResponse {
        // Telegram API для отправки фото с подписью и отложенной публикацией
        // Для каналов бот должен быть администратором с правом публикации
        
        if isLocalFile {
            // Отправляем локальный файл через multipart/form-data
            return try await sendScheduledPhotoFromFile(
                token: token,
                chatId: chatId,
                filePath: photo,
                caption: caption,
                scheduleDate: scheduleDate,
                req: req
            )
        } else {
            // Отправляем URL или file_id через JSON
            let json: [String: Any] = [
                "chat_id": chatId,
                "photo": photo,
                "caption": caption,
                "schedule_date": scheduleDate
            ]
            
            let jsonData = try JSONSerialization.data(withJSONObject: json)
            var buffer = ByteBufferAllocator().buffer(capacity: jsonData.count)
            buffer.writeBytes(jsonData)
            
            req.logger.info("📤 Sending scheduled photo to chat \(chatId) with schedule_date: \(scheduleDate) (Unix timestamp), photo: \(photo.prefix(50))")
            
            var request = ClientRequest(method: .POST, url: URI(string: "https://api.telegram.org/bot\(token)/sendPhoto"))
            request.headers.contentType = .json
            request.body = .init(buffer: buffer)
            
            return try await req.client.send(request)
        }
    }
    
    /// Отправить фото из локального файла через multipart/form-data
    private static func sendScheduledPhotoFromFile(
        token: String,
        chatId: Int64,
        filePath: String,
        caption: String,
        scheduleDate: Int,
        req: Request
    ) async throws -> ClientResponse {
        // Читаем файл
        guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            throw Abort(.internalServerError, reason: "Failed to read image file: \(filePath)")
        }
        
        // Получаем имя файла
        let fileName = (filePath as NSString).lastPathComponent
        
        // Создаем multipart/form-data
        let boundary = UUID().uuidString
        var body = Data()
        
        // chat_id
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(chatId)\r\n".data(using: .utf8)!)
        
        // photo (файл)
        // Определяем MIME type по расширению файла
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        let mimeType: String
        switch fileExtension {
        case "jpg", "jpeg":
            mimeType = "image/jpeg"
        case "png":
            mimeType = "image/png"
        case "gif":
            mimeType = "image/gif"
        case "webp":
            mimeType = "image/webp"
        default:
            mimeType = "image/jpeg"
        }
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        
        // caption
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"caption\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(caption)\r\n".data(using: .utf8)!)
        
        // schedule_date
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"schedule_date\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(scheduleDate)\r\n".data(using: .utf8)!)
        
        // Закрывающий boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        req.logger.info("📤 Sending scheduled photo from local file to chat \(chatId) with schedule_date: \(scheduleDate), file: \(fileName)")
        
        var buffer = ByteBufferAllocator().buffer(capacity: body.count)
        buffer.writeBytes(body)
        
        var request = ClientRequest(method: .POST, url: URI(string: "https://api.telegram.org/bot\(token)/sendPhoto"))
        request.headers.contentType = .init(type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
        request.body = .init(buffer: buffer)
        
        return try await req.client.send(request)
    }
    
    // MARK: - Вспомогательные методы
    
    static func getChatIdFromUserId(userId: Int64) -> Int64 {
        // Для приватных чатов chatId = userId
        return userId
    }
    
    /// Получить информацию о канале, включая фото профиля (если доступно)
    static func getChannelInfo(
        token: String,
        channelId: Int64,
        req: Request
    ) async throws -> ChannelInfo? {
        struct GetChatRequest: Content {
            let chat_id: Int64
        }
        
        let payload = GetChatRequest(chat_id: channelId)
        
        let response = try await req.client.post("https://api.telegram.org/bot\(token)/getChat") { request in
            try request.content.encode(payload, as: .json)
        }
        
        guard response.status == .ok,
              let body = response.body,
              let bodyString = body.getString(at: 0, length: body.readableBytes, encoding: .utf8),
              let data = bodyString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any] else {
            req.logger.warning("⚠️ Failed to get channel info for \(channelId)")
            return nil
        }
        
        // Пытаемся получить фото профиля
        // Telegram API возвращает photo с полями small_file_id и big_file_id
        var photoFileId: String? = nil
        if let photo = result["photo"] as? [String: Any] {
            // Используем big_file_id для лучшего качества
            photoFileId = photo["big_file_id"] as? String ?? photo["small_file_id"] as? String
        }
        
        if let photoFileId = photoFileId {
            req.logger.info("✅ Found channel avatar: \(photoFileId)")
        } else {
            req.logger.info("ℹ️ Channel \(channelId) has no avatar")
        }
        
        return ChannelInfo(
            title: result["title"] as? String,
            username: result["username"] as? String,
            photoFileId: photoFileId
        )
    }
}

// MARK: - Telegram API Models

private struct TelegramSendMessageRequest: Content {
    let chat_id: Int64
    let text: String
    let reply_to_message_id: Int?
    
    enum CodingKeys: String, CodingKey {
        case chat_id
        case text
        case reply_to_message_id
    }
}

private struct TelegramScheduledMessageRequest: Content {
    let chat_id: Int64
    let text: String
    let schedule_date: Int
    
    enum CodingKeys: String, CodingKey {
        case chat_id
        case text
        case schedule_date
    }
}

private struct TelegramScheduledPhotoRequest: Content {
    let chat_id: Int64
    let photo: String  // URL или file_id
    let caption: String
    let schedule_date: Int
    
    enum CodingKeys: String, CodingKey {
        case chat_id
        case photo
        case caption
        case schedule_date
    }
}

private struct TelegramSendMessageWithKeyboardRequest: Content {
    let chat_id: Int64
    let text: String
    let reply_markup: InlineKeyboardMarkup
    let reply_to_message_id: Int?
    
    enum CodingKeys: String, CodingKey {
        case chat_id
        case text
        case reply_markup
        case reply_to_message_id
    }
}

struct InlineKeyboardMarkup: Content {
    let inline_keyboard: [[InlineKeyboardButton]]
}

struct InlineKeyboardButton: Content {
    let text: String
    let callback_data: String
}

private struct TelegramAnswerCallbackQueryRequest: Content {
    let callback_query_id: String
    let text: String?
    let show_alert: Bool
}

struct ChannelInfo {
    let title: String?
    let username: String?
    let photoFileId: String?
}

