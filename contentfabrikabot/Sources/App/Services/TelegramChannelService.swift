import Vapor
import Foundation
import Fluent

struct TelegramChannelService {
    private let botToken: String
    private let client: Client
    private let logger: Logger
    
    init(botToken: String, client: Client, logger: Logger) {
        self.botToken = botToken
        self.client = client
        self.logger = logger
    }
    
    /// Получает последние N постов из канала
    /// Примечание: Telegram Bot API не позволяет напрямую получать историю сообщений из канала
    /// Для этого нужно использовать forwardMessage или хранить сообщения при их публикации
    /// Этот метод возвращает сообщения, которые бот видел через webhook
    func getChannelPosts(chatId: Int64, limit: Int = 10) async throws -> [ChannelPost] {
        // ВАЖНО: Telegram Bot API не предоставляет прямой способ получить историю сообщений канала
        // Для работы с каналами нужно:
        // 1. Либо использовать forwardMessage (если бот админ)
        // 2. Либо хранить сообщения в БД при их публикации через webhook
        // 3. Либо использовать getUpdates (но это только новые сообщения)
        
        // Временное решение: пытаемся получить через forwardMessage
        // Но это требует, чтобы бот был админом и имел доступ к сообщениям
        
        // Альтернатива: использовать метод для получения сообщений через forwardMessage
        // Но для этого нужно знать message_id последних сообщений
        
        // Пока возвращаем пустой массив - логику получения постов нужно реализовать
        // через сохранение сообщений в БД при их публикации в канале
        logger.warning("getChannelPosts: Telegram Bot API не позволяет напрямую получать историю канала. Нужно хранить сообщения в БД при публикации.")
        return []
    }
    
    /// Альтернативный метод: получает посты через forwardMessage (если известны message_id)
    func getPostsByMessageIds(chatId: Int64, messageIds: [Int]) async throws -> [ChannelPost] {
        let posts: [ChannelPost] = []
        
        for messageId in messageIds {
            // Пытаемся получить сообщение через forwardMessage или getChat
            // Но это тоже ограничено API
            logger.info("Attempting to get message \(messageId) from chat \(chatId)")
        }
        
        return posts
    }
    
    /// Получает информацию о канале
    func getChatInfo(chatId: Int64) async throws -> ChatInfo {
        let url = URI(string: "https://api.telegram.org/bot\(botToken)/getChat?chat_id=\(chatId)")
        let response = try await client.get(url)
        
        guard response.status == .ok, let body = response.body else {
            throw Abort(.badRequest, reason: "Failed to get chat info from Telegram")
        }
        
        let data = body.getData(at: 0, length: body.readableBytes) ?? Data()
        let chatResponse = try JSONDecoder().decode(TelegramChatResponse.self, from: data)
        
        guard chatResponse.ok else {
            throw Abort(.badRequest, reason: "Telegram API returned ok=false for getChat")
        }
        
        return ChatInfo(
            id: chatResponse.result.id,
            title: chatResponse.result.title,
            type: chatResponse.result.type
        )
    }
}

struct ChatInfo {
    let id: Int64
    let title: String?
    let type: String
}

private struct TelegramUpdatesResponse: Decodable {
    let ok: Bool
    let result: [TelegramUpdateItem]
}

private struct TelegramUpdateItem: Decodable {
    let update_id: Int?
    let message: TelegramMessageItem?
}

private struct TelegramMessageItem: Decodable {
    let message_id: Int
    let chat: TelegramChatItem
    let text: String?
    let date: Int?
}

private struct TelegramChatItem: Decodable {
    let id: Int64
    let type: String?
    let title: String?
}

private struct TelegramChatResponse: Decodable {
    let ok: Bool
    let result: TelegramChatResult
}

private struct TelegramChatResult: Decodable {
    let id: Int64
    let type: String
    let title: String?
}

