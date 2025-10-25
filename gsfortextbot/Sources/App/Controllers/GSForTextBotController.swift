import Vapor

final class GSForTextBotController {
    func handleWebhook(_ req: Request) async throws -> Response {
        _ = Environment.get("GSFORTEXTBOT_TOKEN")
        return Response(status: .ok)
    }
}
