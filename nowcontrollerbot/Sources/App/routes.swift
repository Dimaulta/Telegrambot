import Vapor

func routes(_ app: Application) throws {
    // Webhook endpoint для Telegram
    app.post("webhook") { req async throws in
        try await NowControllerBotController().handleWebhook(req)
    }
    
    // Health check endpoint
    app.get("health") { _ in
        return "ok"
    }
}
