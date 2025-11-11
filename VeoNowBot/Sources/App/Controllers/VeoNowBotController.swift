import Vapor

struct VeoNowBotController: Sendable {
    private let veoApiClient: VeoApiClient

    init(veoApiClient: VeoApiClient = VeoApiClient()) {
        self.veoApiClient = veoApiClient
    }

    func handleWebhook(_ req: Request) async throws -> Response {
        let update: TelegramUpdate
        do {
            update = try req.content.decode(TelegramUpdate.self)
        } catch {
            req.logger.error("Failed to decode Telegram update: \(error.localizedDescription)")
            return Response(status: .ok)
        }

        guard let chatId = update.message?.chat.id,
              let text = update.message?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.isEmpty == false else {
            req.logger.info("No text message to process")
            return Response(status: .ok)
        }

        let botToken = Environment.get("VEONOWBOT_TOKEN") ?? ""
        guard botToken.isEmpty == false else {
            req.logger.error("VEONOWBOT_TOKEN is not configured")
            return Response(status: .internalServerError)
        }

        let client = req.client
        do {
            try await TelegramClient.sendMessage(
                token: botToken,
                chatId: chatId,
                text: "Приняла описание, запускаю генерацию видео в Veo 3 💫",
                client: client
            )

            let job = try await veoApiClient.createVideo(prompt: text, client: client, logger: req.logger)
            req.logger.info("Veo job created: \(job.id)")

            try await TelegramClient.sendMessage(
                token: botToken,
                chatId: chatId,
                text: "Заявка отправлена. Я пришлю ссылку, как только Veo 3 закончит ☺️",
                client: client
            )
        } catch {
            req.logger.error("Failed to process Veo request: \(error.localizedDescription)")
            try? await TelegramClient.sendMessage(
                token: botToken,
                chatId: chatId,
                text: "Не вышло поставить задачу. Попробуй ещё раз чуть позже 💛",
                client: client
            )
        }

        return Response(status: .ok)
    }
}

