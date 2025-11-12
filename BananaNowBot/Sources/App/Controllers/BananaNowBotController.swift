import Vapor

final class BananaNowBotController {
    private let mediaService: BananaNowMediaService

    init(mediaService: BananaNowMediaService = BananaNowMediaService()) {
        self.mediaService = mediaService
    }

    func handleWebhook(_ req: Request) async throws -> Response {
        guard let token = Environment.get("BANANANOWBOT_TOKEN"), token.isEmpty == false else {
            req.logger.error("BANANANOWBOT_TOKEN отсутствует — проверь config/.env")
            return Response(status: .internalServerError)
        }

        guard let update = try? req.content.decode(BananaNowBotUpdate.self) else {
            req.logger.warning("Не удалось декодировать BananaNowBotUpdate")
            return Response(status: .ok)
        }

        guard let message = update.message ?? update.edited_message else {
            req.logger.debug("Обновление не содержит message / edited_message — пропускаю")
            return Response(status: .ok)
        }

        let text = (message.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let chatId = message.chat.id

        if text == "/start" {
            try await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: """
                Привет! 🍌 Я BananaNowBot — помогу с визуализацией идей.
                Отправь описание сцены, а я подготовлю изображение, отредактирую присланную картинку или соберу короткое видео.
                """,
                client: req.client
            )
            return Response(status: .ok)
        }

        if text.isEmpty {
            req.logger.info("Получено сообщение без текста — предлагаю инструкцию")
            try await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: "Пришли описание желаемой сцены. Можно добавить фото, если нужно внести правки 💛",
                client: req.client
            )
            return Response(status: .ok)
        }

        let attachmentId = message.photo?.last?.file_id ?? message.document?.file_id
        let plan = mediaService.plan(for: text, attachmentFileId: attachmentId, logger: req.logger)

        if let media = plan.media, let url = media.url {
            switch media.kind {
            case .image, .imageEdit:
                try await sendTelegramPhoto(
                    token: token,
                    chatId: chatId,
                    url: url,
                    caption: media.caption ?? plan.responseText,
                    client: req.client
                )
            case .video:
                try await sendTelegramVideo(
                    token: token,
                    chatId: chatId,
                    url: url,
                    caption: media.caption ?? plan.responseText,
                    client: req.client
                )
            }
        } else {
            try await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: plan.responseText,
                client: req.client
            )
        }

        return Response(status: .ok)
    }

    private func sendTelegramMessage(token: String, chatId: Int64, text: String, client: Client) async throws {
        let payload = TelegramTextRequest(chat_id: chatId, text: text)
        _ = try await client.post("https://api.telegram.org/bot\(token)/sendMessage") { request in
            try request.content.encode(payload, as: .json)
        }
    }

    private func sendTelegramPhoto(token: String, chatId: Int64, url: String, caption: String?, client: Client) async throws {
        let payload = TelegramPhotoRequest(chat_id: chatId, photo: url, caption: caption)
        _ = try await client.post("https://api.telegram.org/bot\(token)/sendPhoto") { request in
            try request.content.encode(payload, as: .json)
        }
    }

    private func sendTelegramVideo(token: String, chatId: Int64, url: String, caption: String?, client: Client) async throws {
        let payload = TelegramVideoRequest(chat_id: chatId, video: url, caption: caption)
        _ = try await client.post("https://api.telegram.org/bot\(token)/sendVideo") { request in
            try request.content.encode(payload, as: .json)
        }
    }
}

private struct TelegramTextRequest: Content {
    let chat_id: Int64
    let text: String
}

private struct TelegramPhotoRequest: Content {
    let chat_id: Int64
    let photo: String
    let caption: String?
}

private struct TelegramVideoRequest: Content {
    let chat_id: Int64
    let video: String
    let caption: String?
}


