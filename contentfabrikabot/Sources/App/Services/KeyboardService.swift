import Vapor

/// Сервис для создания стандартных клавиатур с кнопками
struct KeyboardService {
    
    /// Создать клавиатуру с кнопкой "Изучить канал" и "Удалить все данные"
    static func createAnalyzeChannelKeyboard() -> InlineKeyboardMarkup {
        return InlineKeyboardMarkup(inline_keyboard: [
            [
                InlineKeyboardButton(text: "📚 Изучить канал", callback_data: "analyze_channel")
            ],
            [
                InlineKeyboardButton(text: "🗑️ Удалить все данные", callback_data: "reset_all_data")
            ]
        ])
    }
    
    /// Создать клавиатуру только с кнопкой "Удалить все данные"
    static func createDeleteDataKeyboard() -> InlineKeyboardMarkup {
        return InlineKeyboardMarkup(inline_keyboard: [[
            InlineKeyboardButton(text: "🗑️ Удалить все данные", callback_data: "reset_all_data")
        ]])
    }
    
    /// Создать клавиатуру с кнопкой "Сгенерировать пост" и "Удалить все данные"
    static func createGeneratePostKeyboard() -> InlineKeyboardMarkup {
        return InlineKeyboardMarkup(inline_keyboard: [
            [
                InlineKeyboardButton(text: "🤖 Сгенерировать пост", callback_data: "create_new_post")
            ],
            [
                InlineKeyboardButton(text: "🗑️ Удалить все данные", callback_data: "reset_all_data")
            ]
        ])
    }
    
    /// Создать клавиатуру с кнопкой "Переизучить канал" и "Удалить все данные"
    static func createRelearnKeyboard() -> InlineKeyboardMarkup {
        return InlineKeyboardMarkup(inline_keyboard: [
            [
                InlineKeyboardButton(text: "🔄 Переизучить канал", callback_data: "relearn_style")
            ],
            [
                InlineKeyboardButton(text: "🗑️ Удалить все данные", callback_data: "reset_all_data")
            ]
        ])
    }
    
    /// Создать клавиатуру с кнопкой "Изучить канал" (без кнопки удаления)
    static func createSimpleAnalyzeKeyboard() -> InlineKeyboardMarkup {
        return InlineKeyboardMarkup(inline_keyboard: [[
            InlineKeyboardButton(text: "📚 Изучить канал", callback_data: "analyze_channel")
        ]])
    }
}

