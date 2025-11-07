import Vapor

final class NeurfotobotController {
    func handleWebhook(_ req: Request) async throws -> Response {
        guard let token = Environment.get("NEURFOTOBOT_TOKEN"), !token.isEmpty else {
            req.logger.error("NEURFOTOBOT_TOKEN is missing")
            return Response(status: .internalServerError)
        }

        guard let update = try? req.content.decode(NeurfotobotUpdate.self) else {
            req.logger.warning("Failed to decode NeurfotobotUpdate")
            return Response(status: .ok)
        }

        guard let message = update.message else {
            req.logger.info("No message payload in update \(update.update_id)")
            return Response(status: .ok)
        }

        let text = message.text ?? ""
        if text == "/start" {
            let welcomeMessage = """
Привет! Загрузи десять своих фотографий где хорошо видно лицо. Я соберу модель за несколько минут и по твоему промпту верну фото с твоим участием!

⏳ Обычно всё готово за несколько минут. Мы сообщим, когда модель соберётся и можно будет придумать образ. Чтобы всем было комфортно, автоматически проверяем фотографии через SafeSearch, а промпты через Azure. Добросовестных пользователей это никак не затрагивает, но любой незаконный контент блокируется и фиксируется в логах
"""

            do {
                try await sendTelegramMessage(
                    token: token,
                    chatId: message.chat.id,
                    text: welcomeMessage,
                    client: req.client
                )
            } catch {
                req.logger.error("Failed to send welcome message: \(error)")
            }
        }

        return Response(status: .ok)
    }

    private func sendTelegramMessage(token: String, chatId: Int64, text: String, client: Client) async throws {
        let encodedText = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage?chat_id=\(chatId)&text=\(encodedText)")
        _ = try await client.get(url)
    }
} 