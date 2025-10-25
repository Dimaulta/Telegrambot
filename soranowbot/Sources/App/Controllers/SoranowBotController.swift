import Vapor

final class SoranowBotController {
    func handleWebhook(_ req: Request) async throws -> Response {
        _ = Environment.get("SORANOWBOT_TOKEN")
        return Response(status: .ok)
    }
}
