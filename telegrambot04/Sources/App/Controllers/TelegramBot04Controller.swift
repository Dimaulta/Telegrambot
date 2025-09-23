import Vapor

final class TelegramBot04Controller {
    func handleWebhook(_ req: Request) async throws -> Response {
        _ = Environment.get("TELEGRAMBOT04_TOKEN") // пример использования
        return Response(status: .ok)
    }
}
