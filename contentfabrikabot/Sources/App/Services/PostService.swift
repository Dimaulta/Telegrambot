import Vapor
import Fluent

/// Сервис для работы с постами
struct PostService {
    
    /// Сохранить пересланный пост от пользователя
    static func saveForwardedPost(
        message: ContentFabrikaBotMessage,
        userId: Int64,
        token: String,
        req: Request
    ) async throws -> Int {
        guard let forwardedChat = message.forward_from_chat,
              forwardedChat.type == "channel" else {
            throw Abort(.badRequest, reason: "Message is not forwarded from channel")
        }
        
        let text = message.text ?? message.caption ?? ""
        // Если текста нет, используем маркер для медиа без текста
        let postText = text.isEmpty ? "[Медиа без текста]" : text
        
        let forwardedChatId = forwardedChat.id
        
        // Находим или создаем канал
        var channel = try await Channel.query(on: req.db)
            .filter(\.$telegramChatId == forwardedChatId)
            .first()
        
        if channel == nil {
            channel = Channel(
                telegramChatId: forwardedChatId,
                telegramChatTitle: forwardedChat.title,
                ownerUserId: userId
            )
            try await channel!.save(on: req.db)
        }
        
        guard let channel = channel else {
            throw Abort(.internalServerError, reason: "Failed to create or find channel")
        }
        
        // Обновляем ownerUserId если нужно
        if channel.ownerUserId == 0 {
            channel.ownerUserId = userId
            try await channel.save(on: req.db)
        }
        
        let channelId = try channel.requireID()
        
        // Проверяем, не сохранили ли мы уже этот пост
        let existingPost = try await ChannelPost.query(on: req.db)
            .filter(\.$channel.$id == channelId)
            .filter(\.$telegramMessageId == message.message_id)
            .first()
        
        if existingPost == nil {
            // Сохраняем пересланный пост
            let post = ChannelPost(
                channelID: channelId,
                telegramMessageId: message.message_id,
                text: postText,
                postDate: message.date ?? Int(Date().timeIntervalSince1970)
            )
            try await post.save(on: req.db)
            
            req.logger.info("✅ Saved forwarded post from channel \(forwardedChatId) by user \(userId), hasText: \(!text.isEmpty)")
        }
        
        // Возвращаем количество постов в канале
        return try await ChannelPost.query(on: req.db)
            .filter(\.$channel.$id == channelId)
            .count()
    }
    
    /// Получить статистику постов канала
    static func getPostsStatistics(
        channelId: UUID,
        db: Database
    ) async throws -> (total: Int, withText: Int, mediaOnly: Int) {
        let allPosts = try await ChannelPost.query(on: db)
            .filter(\.$channel.$id == channelId)
            .all()
        
        let total = allPosts.count
        let withText = allPosts.filter { post in
            let text = post.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && text != "[Медиа без текста]"
        }.count
        let mediaOnly = total - withText
        
        return (total: total, withText: withText, mediaOnly: mediaOnly)
    }
    
    /// Проверить, есть ли у поста текст (не маркер)
    static func hasText(_ post: ChannelPost) -> Bool {
        let text = post.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text != "[Медиа без текста]"
    }
    
    /// Получить последние посты канала
    static func getRecentPosts(
        channelId: UUID,
        limit: Int,
        db: Database
    ) async throws -> [ChannelPost] {
        return try await ChannelPost.query(on: db)
            .filter(\.$channel.$id == channelId)
            .sort(\.$postDate, .descending)
            .limit(limit)
            .all()
    }
}

