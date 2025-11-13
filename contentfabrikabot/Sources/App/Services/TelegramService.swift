import Vapor
import Foundation

/// Сервис для работы с Telegram Bot API
struct TelegramService {
    
    /// Отправка простого сообщения
    @discardableResult
    static func sendMessage(
        token: String,
        chatId: Int64,
        text: String,
        client: Client,
        replyToMessageId: Int? = nil
    ) async throws -> Int? {
        let payload = TelegramSendMessageRequest(
            chat_id: chatId,
            text: text,
            reply_to_message_id: replyToMessageId
        )
        
        let response = try await client.post("https://api.telegram.org/bot\(token)/sendMessage") { request in
            try request.content.encode(payload, as: .json)
        }
        
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
    
    /// Отправка сообщения с inline-клавиатурой
    @discardableResult
    static func sendMessageWithKeyboard(
        token: String,
        chatId: Int64,
        text: String,
        keyboard: InlineKeyboardMarkup,
        client: Client,
        replyToMessageId: Int? = nil
    ) async throws -> Int? {
        let payload = TelegramSendMessageWithKeyboardRequest(
            chat_id: chatId,
            text: text,
            reply_markup: keyboard,
            reply_to_message_id: replyToMessageId
        )
        
        let response = try await client.post("https://api.telegram.org/bot\(token)/sendMessage") { request in
            try request.content.encode(payload, as: .json)
        }
        
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
    
    /// Ответ на callback query
    static func answerCallbackQuery(
        token: String,
        callbackId: String,
        text: String?,
        req: Request
    ) async throws {
        let payload = TelegramAnswerCallbackQueryRequest(
            callback_query_id: callbackId,
            text: text,
            show_alert: false
        )
        
        _ = try await req.client.post("https://api.telegram.org/bot\(token)/answerCallbackQuery") { request in
            try request.content.encode(payload, as: .json)
        }
    }
    
    /// Для приватных чатов chatId = userId
    static func getChatIdFromUserId(userId: Int64) -> Int64 {
        return userId
    }
}

// MARK: - Модели API

private struct TelegramSendMessageRequest: Content {
    let chat_id: Int64
    let text: String
    let reply_to_message_id: Int?
}

private struct TelegramSendMessageWithKeyboardRequest: Content {
    let chat_id: Int64
    let text: String
    let reply_markup: InlineKeyboardMarkup
    let reply_to_message_id: Int?
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

