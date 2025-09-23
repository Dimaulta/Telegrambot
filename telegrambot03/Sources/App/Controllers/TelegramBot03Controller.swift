import Vapor

final class TelegramBot03Controller {
    func handleWebhook(_ req: Request) async throws -> Response {
        _ = Environment.get("TELEGRAMBOT03_TOKEN") // пример использования
        return Response(status: .ok)
    }
}
