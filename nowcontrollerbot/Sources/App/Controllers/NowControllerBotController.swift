import Vapor
import Foundation

final class NowControllerBotController {
    func handleWebhook(_ req: Request) async throws -> Response {
        req.logger.info("🔔 NowControllerBot webhook hit!")
        req.logger.info("Method: \(req.method), Path: \(req.url.path)")
        
        let token = Environment.get("NOWCONTROLLERBOT_TOKEN")
        guard let token = token, token.isEmpty == false else {
            req.logger.error("NOWCONTROLLERBOT_TOKEN is missing")
            return Response(status: .internalServerError)
        }

        let rawBody = req.body.string ?? ""
        req.logger.info("📦 Raw body length: \(rawBody.count) characters")
        if rawBody.count > 0 && rawBody.count < 500 {
            req.logger.debug("Raw body: \(rawBody)")
        }

        req.logger.info("🔍 Decoding NowControllerBotUpdate...")
        let update = try? req.content.decode(NowControllerBotUpdate.self)
        if update == nil {
            req.logger.error("❌ Failed to decode NowControllerBotUpdate - check raw body above")
            return Response(status: .ok)
        }
        req.logger.info("✅ NowControllerBotUpdate decoded successfully")

        guard let message = update?.message else {
            req.logger.warning("⚠️ No message in update (update_id: \(update?.update_id ?? -1))")
            return Response(status: .ok)
        }
        
        let text = message.text ?? ""
        let chatId = message.chat.id
        
        req.logger.info("📨 Incoming message - chatId=\(chatId), text length=\(text.count)")
        if !text.isEmpty {
            req.logger.info("📝 Message text: \(text.prefix(200))")
        }

        // TODO: Реализовать логику обработки сообщений
        // Пример: обработка команды /start
        if text == "/start" {
            let welcomeText = "Привет! Это NowControllerBot.\n\nФункционал в разработке."
            _ = try? await sendTelegramMessage(token: token, chatId: chatId, text: welcomeText, client: req.client)
        }

        return Response(status: .ok)
    }
}

// MARK: - Helper Functions

private func sendTelegramMessage(token: String, chatId: Int64, text: String, client: Client) async throws -> Bool {
    struct Payload: Content {
        let chat_id: Int64
        let text: String
        let disable_web_page_preview: Bool
    }
    
    let payload = Payload(chat_id: chatId, text: text, disable_web_page_preview: false)
    let url = "https://api.telegram.org/bot\(token)/sendMessage"
    let res = try await client.post(URI(string: url)) { req in
        try req.content.encode(payload, as: .json)
    }
    return res.status == .ok
}
