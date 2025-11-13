import Vapor
import Fluent

/// Сервис для работы с каналами
struct ChannelService {
    
    /// Найти канал пользователя (первый активный)
    static func findUserChannel(ownerUserId: Int64, db: Database) async throws -> Channel? {
        return try await Channel.query(on: db)
            .filter(\.$ownerUserId == ownerUserId)
            .filter(\.$isActive == true)
            .first()
    }
    
    /// Найти все каналы пользователя
    static func findAllUserChannels(ownerUserId: Int64, db: Database) async throws -> [Channel] {
        return try await Channel.query(on: db)
            .filter(\.$ownerUserId == ownerUserId)
            .filter(\.$isActive == true)
            .all()
    }
    
    /// Найти канал по telegramChatId
    static func findChannelByTelegramId(telegramChatId: Int64, ownerUserId: Int64, db: Database) async throws -> Channel? {
        return try await Channel.query(on: db)
            .filter(\.$telegramChatId == telegramChatId)
            .filter(\.$ownerUserId == ownerUserId)
            .filter(\.$isActive == true)
            .first()
    }
    
    /// Создать или обновить канал при добавлении бота
    static func createOrUpdateChannel(
        telegramChatId: Int64,
        telegramChatTitle: String?,
        ownerUserId: Int64,
        db: Database
    ) async throws -> Channel {
        if let existingChannel = try await Channel.query(on: db)
            .filter(\.$telegramChatId == telegramChatId)
            .first() {
            // Обновляем существующий канал
            existingChannel.telegramChatTitle = telegramChatTitle
            existingChannel.ownerUserId = ownerUserId
            existingChannel.isActive = true
            try await existingChannel.save(on: db)
            return existingChannel
        } else {
            // Создаем новый канал
            let newChannel = Channel(
                telegramChatId: telegramChatId,
                telegramChatTitle: telegramChatTitle,
                ownerUserId: ownerUserId
            )
            try await newChannel.save(on: db)
            return newChannel
        }
    }
}

