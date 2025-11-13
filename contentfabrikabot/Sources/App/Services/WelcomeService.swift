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
        var welcomeMessage = """
Привет! Я сгенерирую текст для публикации в твоём стиле! 

1. Перешли мне три публикации из канала
2. Появится кнопка «Изучить канал», нажми её, и я запомню стиль
3. Отправь тему или промт, а я верну готовый текст, который ты копируешь себе

(Ограничение на частоту генераций: до двух генераций в минуту)

"""

        welcomeMessage += "\n"
        
        let channels = try await ChannelService.findAllUserChannels(ownerUserId: userId, db: req.db)
        var totalSavedPosts = 0
        
        if channels.isEmpty {
            welcomeMessage += """
⚠️ Тут пока нет сохранённых постов. Перешли мне три публикации из канала
"""
        } else {
            welcomeMessage += "\n\n📂 Что у меня уже есть:"
            var summaries: [String] = []
            var hasReadyStyle = false
            var hasEnoughPosts = false
            
            for channel in channels {
                let channelId = try channel.requireID()
                let title = channel.telegramChatTitle ?? "Канал \(channel.telegramChatId)"
                let postsCount = try await ChannelPost.query(on: req.db)
                    .filter(\.$channel.$id == channelId)
                    .count()
                totalSavedPosts += postsCount
                let hasStyleProfile = (try? await StyleProfile.query(on: req.db)
                    .filter(\.$channel.$id == channelId)
                    .filter(\.$isReady == true)
                    .first()) != nil
                
                if hasStyleProfile { hasReadyStyle = true }
                if postsCount >= 3 { hasEnoughPosts = true }
                
                let status: String
                if hasStyleProfile {
                    status = "стиль изучен — можно сразу генерировать"
                } else if postsCount >= 3 {
                    status = "готов к анализу"
                } else if postsCount == 0 {
                    status = "пока нет сохранённых постов"
                } else {
                    status = "нужно ещё \(max(0, 3 - postsCount)) пост(а) для анализа"
                }
                
                summaries.append("• \(title): \(status) (сохранено \(postsCount))")
            }
            
            if !summaries.isEmpty {
                welcomeMessage += "\n" + summaries.joined(separator: "\n")
            }
            
            welcomeMessage += "\n\n📝 Готовые тексты я отправляю в этот чат — автор публикует их вручную, когда удобно."
            
            var buttons: [[InlineKeyboardButton]] = []
            
            if hasEnoughPosts {
                buttons.append([
                    InlineKeyboardButton(text: "📚 Изучить канал", callback_data: "analyze_channel")
                ])
            }
            
            if hasReadyStyle {
                buttons.append([
                    InlineKeyboardButton(text: "🤖 Сгенерировать пост", callback_data: "create_new_post")
                ])
                buttons.append([
                    InlineKeyboardButton(text: "🔄 Переизучить канал", callback_data: "relearn_style")
                ])
            }
            
            buttons.append([
                InlineKeyboardButton(text: KeyboardService.deleteButtonTitle(totalCount: totalSavedPosts), callback_data: "reset_all_data")
            ])
            
            let keyboard = InlineKeyboardMarkup(inline_keyboard: buttons)
            
            try await TelegramService.sendMessageWithKeyboard(
                token: token,
                chatId: chatId,
                text: welcomeMessage,
                keyboard: keyboard,
                client: req.client
            )
            return
        }
        
        let keyboard = KeyboardService.createDeleteDataKeyboard(totalCount: totalSavedPosts)
        
        try await TelegramService.sendMessageWithKeyboard(
            token: token,
            chatId: chatId,
            text: welcomeMessage,
            keyboard: keyboard,
            client: req.client
        )
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

