import Vapor

/// Сервис для создания стандартных клавиатур с кнопками
struct KeyboardService {
    
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
}

