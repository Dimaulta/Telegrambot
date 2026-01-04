import Vapor
import Logging

struct AntiSpamService {
    func plan(for text: String, attachmentFileId: String?, logger: Logger) -> AntispamNowBotResult {
        let cleanedPrompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = resolveMode(prompt: cleanedPrompt, attachmentFileId: attachmentFileId)

        logger.info("AntiSpamService план: mode=\(mode.rawValue), hasAttachment=\(attachmentFileId != nil)")

        let meta = AntispamNowBotMeta(mode: mode, prompt: cleanedPrompt, referenceFileId: attachmentFileId)
        let preview = previewMessage(for: meta)

        // TODO: добавить реальную логику антиспама.
        return AntispamNowBotResult(responseText: preview, media: nil, meta: meta)
    }

    private func resolveMode(prompt: String, attachmentFileId: String?) -> AntispamNowMediaKind {
        let lowercased = prompt.lowercased()

        if lowercased.contains("капча") || lowercased.contains("captcha") {
            return .captcha
        }

        if lowercased.contains("ночь") || lowercased.contains("night") || lowercased.contains("выключ") {
            return .nightMode
        }

        return .channelBlock
    }

    private func previewMessage(for meta: AntispamNowBotMeta) -> String {
        switch meta.mode {
        case .captcha:
            return """
            🛡️ Настройка капчи для вступления в группу.
            Промпт: "\(meta.prompt)"

            TODO: реализовать капчу.
            """
        case .nightMode:
            return """
            🛡️ Настройка выключателя на ночь.
            Промпт: "\(meta.prompt)"

            TODO: реализовать ночной режим.
            """
        case .channelBlock:
            return """
            🛡️ Настройка запрета сообщений от каналов.
            Промпт: "\(meta.prompt)"

            TODO: реализовать блокировку каналов.
            """
        }
    }
}


