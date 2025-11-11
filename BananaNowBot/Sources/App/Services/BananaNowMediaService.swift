import Vapor
import Logging

struct BananaNowMediaService {
    func plan(for text: String, attachmentFileId: String?, logger: Logger) -> BananaNowBotResult {
        let cleanedPrompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = resolveMode(prompt: cleanedPrompt, attachmentFileId: attachmentFileId)

        logger.info("BananaNowMediaService план: mode=\(mode.rawValue), hasAttachment=\(attachmentFileId != nil)")

        let meta = BananaNowBotMeta(mode: mode, prompt: cleanedPrompt, referenceFileId: attachmentFileId)
        let preview = previewMessage(for: meta)

        // TODO: добавить реальные URL после интеграции с Nano Banana API.
        return BananaNowBotResult(responseText: preview, media: nil, meta: meta)
    }

    private func resolveMode(prompt: String, attachmentFileId: String?) -> BananaNowMediaKind {
        let lowercased = prompt.lowercased()

        if lowercased.contains("видео") || lowercased.contains("video") || lowercased.contains("clip") {
            return .video
        }

        if attachmentFileId != nil ||
            lowercased.contains("редакт") ||
            lowercased.contains("edit") ||
            lowercased.contains("исправь") {
            return .imageEdit
        }

        return .image
    }

    private func previewMessage(for meta: BananaNowBotMeta) -> String {
        switch meta.mode {
        case .image:
            return """
            🍌 Готовлю запрос в Nano Banana на генерацию изображения.
            Промпт: "\(meta.prompt)"

            TODO: заменить этот текст на результат после интеграции с API.
            """
        case .imageEdit:
            let referenceInfo = meta.referenceFileId.map { "\nРеференс: \($0)" } ?? ""
            return """
            🍌 Запланировано редактирование изображения в Nano Banana.
            Промпт: "\(meta.prompt)"\(referenceInfo)

            TODO: вернуть ссылку на обновлённую картинку.
            """
        case .video:
            return """
            🍌 Подготавливаю запрос в Nano Banana на генерацию видео.
            Промпт: "\(meta.prompt)"

            TODO: прикрепить ссылку на готовый ролик.
            """
        }
    }
}


