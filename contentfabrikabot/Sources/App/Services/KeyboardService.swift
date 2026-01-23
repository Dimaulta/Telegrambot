import Vapor

/// Сервис для создания стандартных клавиатур с кнопками
struct KeyboardService {
    
    /// Правильное склонение слова "пост"
    static func pluralizePost(_ count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        
        if mod100 >= 11 && mod100 <= 19 {
            return "\(count) постов"
        } else if mod10 == 1 {
            return "\(count) пост"
        } else if mod10 >= 2 && mod10 <= 4 {
            return "\(count) поста"
        } else {
            return "\(count) постов"
        }
    }
    
    /// Правильное склонение слова "канал"
    static func pluralizeChannel(_ count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        
        if mod100 >= 11 && mod100 <= 19 {
            return "\(count) каналов"
        } else if mod10 == 1 {
            return "\(count) канал"
        } else if mod10 >= 2 && mod10 <= 4 {
            return "\(count) канала"
        } else {
            return "\(count) каналов"
        }
    }
    
    /// Правильное склонение слова "профиль"
    static func pluralizeProfile(_ count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        
        if mod100 >= 11 && mod100 <= 19 {
            return "\(count) профилей"
        } else if mod10 == 1 {
            return "\(count) профиль"
        } else if mod10 >= 2 && mod10 <= 4 {
            return "\(count) профиля"
        } else {
            return "\(count) профилей"
        }
    }
    
    /// Создать клавиатуру с кнопкой "Изучить канал" и "Удалить все данные"
    /// - Parameters:
    ///   - totalCount: Общее количество постов
    ///   - postsWithText: Количество постов с текстом (для отображения статуса на кнопке)
    static func createAnalyzeChannelKeyboard(totalCount: Int = 0, postsWithText: Int = 0) -> InlineKeyboardMarkup {
        let buttonText: String
        if postsWithText >= 3 {
            buttonText = "📚 Изучить канал ✅"
        } else {
            buttonText = "📚 Изучить канал (\(postsWithText)/3)"
        }
        
        return InlineKeyboardMarkup(inline_keyboard: [
            [
                InlineKeyboardButton(text: buttonText, callback_data: "analyze_channel")
            ],
            [
                InlineKeyboardButton(text: deleteButtonTitle(totalCount: totalCount), callback_data: "reset_all_data")
            ]
        ])
    }
    
    /// Создать клавиатуру только с кнопкой "Удалить все данные"
    static func createDeleteDataKeyboard(totalCount: Int = 0) -> InlineKeyboardMarkup {
        return InlineKeyboardMarkup(inline_keyboard: [[
            InlineKeyboardButton(text: deleteButtonTitle(totalCount: totalCount), callback_data: "reset_all_data")
        ]])
    }
    
    /// Создать клавиатуру с кнопкой "Сгенерировать пост" и "Удалить все данные"
    static func createGeneratePostKeyboard(totalCount: Int = 0) -> InlineKeyboardMarkup {
        return InlineKeyboardMarkup(inline_keyboard: [
            [
                InlineKeyboardButton(text: "🤖 Сгенерировать пост", callback_data: "create_new_post")
            ],
            [
                InlineKeyboardButton(text: deleteButtonTitle(totalCount: totalCount), callback_data: "reset_all_data")
            ]
        ])
    }
    
    /// Создать клавиатуру с кнопкой "Сгенерировать пост", "Удалить все данные" и "Назад"
    static func createGeneratePostKeyboardWithBack(totalCount: Int = 0) -> InlineKeyboardMarkup {
        return InlineKeyboardMarkup(inline_keyboard: [
            [
                InlineKeyboardButton(text: "🤖 Сгенерировать пост", callback_data: "create_new_post")
            ],
            [
                InlineKeyboardButton(text: deleteButtonTitle(totalCount: totalCount), callback_data: "reset_all_data")
            ],
            [
                InlineKeyboardButton(text: "↩️ Назад", callback_data: "back_to_main")
            ]
        ])
    }
    
    /// Создать клавиатуру с кнопкой "Переизучить канал" и "Удалить все данные"
    static func createRelearnKeyboard(totalCount: Int = 0) -> InlineKeyboardMarkup {
        return InlineKeyboardMarkup(inline_keyboard: [
            [
                InlineKeyboardButton(text: "🔄 Переизучить канал", callback_data: "relearn_style")
            ],
            [
                InlineKeyboardButton(text: deleteButtonTitle(totalCount: totalCount), callback_data: "reset_all_data")
            ]
        ])
    }
    
    /// Создать клавиатуру с кнопкой "Изучить канал" (без кнопки удаления)
    static func createSimpleAnalyzeKeyboard() -> InlineKeyboardMarkup {
        return InlineKeyboardMarkup(inline_keyboard: [[
            InlineKeyboardButton(text: "📚 Изучить канал", callback_data: "analyze_channel")
        ]])
    }
    
    /// Клавиатура после генерации поста
    static func createPostResultKeyboard(totalCount: Int = 0) -> InlineKeyboardMarkup {
        return InlineKeyboardMarkup(inline_keyboard: [
            [
                InlineKeyboardButton(text: "🤖 Сгенерировать ещё", callback_data: "create_new_post")
            ],
            [
                InlineKeyboardButton(text: "🔄 Переизучить канал", callback_data: "relearn_style")
            ],
            [
                InlineKeyboardButton(text: deleteButtonTitle(totalCount: totalCount), callback_data: "reset_all_data")
            ]
        ])
    }
    
    static func deleteButtonTitle(totalCount: Int) -> String {
        guard totalCount > 0 else {
            return "🗑️ Удалить все данные"
        }
        return "🗑️ Удалить все данные (\(totalCount))"
    }
    
    /// Создать главное меню
    static func createMainMenuKeyboard(channelsCount: Int, maxChannels: Int) -> InlineKeyboardMarkup {
        var buttons: [[InlineKeyboardButton]] = []
        
        if channelsCount > 0 {
            buttons.append([
                InlineKeyboardButton(text: "📝 Сгенерировать пост", callback_data: "generate_post_menu")
            ])
            buttons.append([
                InlineKeyboardButton(text: "📚 Изучить канал", callback_data: "analyze_channel_menu")
            ])
            buttons.append([
                InlineKeyboardButton(text: "📊 Статистика", callback_data: "show_statistics")
            ])
            buttons.append([
                InlineKeyboardButton(text: "❌ Удалить канал", callback_data: "delete_channel_menu")
            ])
        } else {
            buttons.append([
                InlineKeyboardButton(text: "📊 Мои каналы (\(channelsCount)/\(maxChannels))", callback_data: "show_statistics")
            ])
        }
        
        buttons.append([
            InlineKeyboardButton(text: "❓ Помощь", callback_data: "help")
        ])
        
        return InlineKeyboardMarkup(inline_keyboard: buttons)
    }
    
    /// Создать клавиатуру выбора канала
    static func createChannelSelectionKeyboard(
        channels: [(id: UUID, title: String, canUse: Bool)],
        actionPrefix: String
    ) -> InlineKeyboardMarkup {
        var buttons: [[InlineKeyboardButton]] = []
        
        let emojis = ["1️⃣", "2️⃣", "3️⃣"]
        for (index, channel) in channels.enumerated() {
            let emoji = index < emojis.count ? emojis[index] : "•"
            let buttonText = "\(emoji) \(channel.title)"
            buttons.append([
                InlineKeyboardButton(
                    text: buttonText,
                    callback_data: "\(actionPrefix):\(channel.id.uuidString)"
                )
            ])
        }
        
        buttons.append([
            InlineKeyboardButton(text: "↩️ Назад", callback_data: "back_to_main")
        ])
        
        return InlineKeyboardMarkup(inline_keyboard: buttons)
    }
    
    /// Создать клавиатуру статистики канала
    static func createChannelStatisticsKeyboard(channelId: UUID, channelTitle: String) -> InlineKeyboardMarkup {
        let channelIdString = channelId.uuidString
        return InlineKeyboardMarkup(inline_keyboard: [
            [
                InlineKeyboardButton(text: "📝 Сгенерировать для \(channelTitle)", callback_data: "generate_post:\(channelIdString)")
            ],
            [
                InlineKeyboardButton(text: "🔄 Переизучить \(channelTitle)", callback_data: "relearn_style:\(channelIdString)")
            ],
            [
                InlineKeyboardButton(text: "❌ Удалить \(channelTitle)", callback_data: "delete_channel:\(channelIdString)")
            ],
            [
                InlineKeyboardButton(text: "↩️ Назад", callback_data: "show_statistics")
            ]
        ])
    }
    
    /// Создать клавиатуру подтверждения удаления
    static func createDeleteConfirmationKeyboard(channelId: UUID, channelTitle: String) -> InlineKeyboardMarkup {
        let channelIdString = channelId.uuidString
        return InlineKeyboardMarkup(inline_keyboard: [
            [
                InlineKeyboardButton(text: "✅ Да, удалить", callback_data: "confirm_delete_channel:\(channelIdString)"),
                InlineKeyboardButton(text: "❌ Отмена", callback_data: "cancel_delete:\(channelIdString)")
            ],
            [
                InlineKeyboardButton(text: "↩️ Назад", callback_data: "delete_channel_menu")
            ]
        ])
    }
    
    /// Создать клавиатуру с кнопками назад/отмена
    static func createBackCancelKeyboard(backCallback: String = "back_to_main") -> InlineKeyboardMarkup {
        return InlineKeyboardMarkup(inline_keyboard: [[
            InlineKeyboardButton(text: "↩️ Назад", callback_data: backCallback)
        ]])
    }
    
    /// Создать клавиатуру после генерации поста
    static func createPostResultKeyboardWithBack(totalCount: Int = 0) -> InlineKeyboardMarkup {
        return InlineKeyboardMarkup(inline_keyboard: [
            [
                InlineKeyboardButton(text: "📝 Сгенерировать ещё", callback_data: "generate_post_menu")
            ],
            [
                InlineKeyboardButton(text: "📊 Статистика", callback_data: "show_statistics")
            ],
            [
                InlineKeyboardButton(text: "↩️ Назад", callback_data: "back_to_main")
            ]
        ])
    }
}

