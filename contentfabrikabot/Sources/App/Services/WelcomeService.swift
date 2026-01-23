import Vapor
import Fluent

/// Сервис для приветственных сообщений
struct WelcomeService {
    
    /// Отправить приветственное сообщение
    static func sendWelcome(
        userId: Int64,
        chatId: Int64,
        token: String,
        req: Request
    ) async throws {
        let channels = try await ChannelService.findAllUserChannels(ownerUserId: userId, db: req.db)
        let channelsCount = channels.count
        let maxChannels = 3
        
        var welcomeMessage = """
Привет! Я сгенерирую текст для публикации в твоём стиле!

1. Перешли мне от 3 до 10 постов из канала
2. Появится кнопка «Изучить канал», нажми её, и я запомню стиль
3. Отправь тему или промт, а я верну готовый текст, который ты копируешь себе

(Ограничение на частоту генераций: до двух генераций в минуту)

"""
        
        if channels.isEmpty {
            // Нет каналов
            welcomeMessage += "⚠️ Тут пока нет сохранённых постов. Перешли мне от 3 до 10 постов из канала через Forward."
            
            let keyboard = KeyboardService.createMainMenuKeyboard(channelsCount: 0, maxChannels: maxChannels)
            try await TelegramService.sendMessageWithKeyboard(
                token: token,
                chatId: chatId,
                text: welcomeMessage,
                keyboard: keyboard,
                client: req.client
            )
        } else {
            // Есть каналы - показываем список
            welcomeMessage += "📊 Твои каналы (\(channelsCount)/\(maxChannels)):\n\n"
            
            for (index, channel) in channels.enumerated() {
                let channelId = try channel.requireID()
                let title = channel.telegramChatTitle ?? "Канал \(channel.telegramChatId)"
                let stats = try await PostService.getPostsStatistics(channelId: channelId, db: req.db)
                let hasStyleProfile = (try? await StyleProfile.query(on: req.db)
                    .filter(\.$channel.$id == channelId)
                    .filter(\.$isReady == true)
                    .first()) != nil
                
                let emoji = ["1️⃣", "2️⃣", "3️⃣"][index]
                let status: String
                if hasStyleProfile {
                    status = "✅ Стиль изучен"
                } else if stats.withText >= 3 {
                    status = "⏳ Готов к изучению"
                } else {
                    status = "⏳ Нужно изучить"
                }
                
                welcomeMessage += "\(emoji) \(title)\n"
                welcomeMessage += "   • Постов: \(stats.total) (с текстом: \(stats.withText))\n"
                welcomeMessage += "   • Статус: \(status)\n\n"
            }
            
            let keyboard = KeyboardService.createMainMenuKeyboard(channelsCount: channelsCount, maxChannels: maxChannels)
            try await TelegramService.sendMessageWithKeyboard(
                token: token,
                chatId: chatId,
                text: welcomeMessage,
                keyboard: keyboard,
                client: req.client
            )
        }
    }
    
    /// Напоминание о необходимости переслать публикации
    static func sendForwardReminder(
        userId: Int64,
        chatId: Int64,
        token: String,
        req: Request
    ) async throws {
        let reminder = """
Мне пока не хватает материалов 💛

Перешли от 3 до 10 публикаций из своего канала (Forward), и как только появятся 3 поста, я включу кнопку «Изучить канал». После анализа буду присылать тебе готовые тексты сюда, а публиковать их ты сможешь вручную.
"""
        _ = try await TelegramService.sendMessage(
            token: token,
            chatId: chatId,
            text: reminder,
            client: req.client
        )
    }
}

