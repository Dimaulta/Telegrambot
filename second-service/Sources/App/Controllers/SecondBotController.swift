import Vapor

final class SecondBotController {
    func handleWebhook(_ req: Request) async throws -> Response {
        // Здесь будет логика обработки webhook второго бота
        return Response(status: .ok)
    }
} 