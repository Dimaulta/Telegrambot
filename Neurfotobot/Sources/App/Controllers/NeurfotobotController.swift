import Vapor

final class NeurfotobotController {
    func handleWebhook(_ req: Request) async throws -> Response {
        _ = Environment.get("NEURFOTOBOT_TOKEN")
        return Response(status: .ok)
    }
} 