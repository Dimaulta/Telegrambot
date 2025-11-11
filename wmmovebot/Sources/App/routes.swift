import Vapor

func routes(_ app: Application) throws {
    // Поддерживаем оба пути: /webhook и /sora/webhook (для nginx проксирования)
    app.post("webhook") { req async throws in
        try await WmmoveBotController().handleWebhook(req)
    }
    app.post("sora", "webhook") { req async throws in
        try await WmmoveBotController().handleWebhook(req)
    }
    app.get("health") { _ in
        return "ok"
    }
}
