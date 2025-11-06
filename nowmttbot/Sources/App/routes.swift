import Vapor

func routes(_ app: Application) throws {
    let controller = NowmttBotController()
    app.post("webhook", use: controller.handleWebhook)
    // Дополнительный путь для проксирования через nginx/балансировщик
    app.post("nowmtt", "webhook", use: controller.handleWebhook)
    app.get("health") { _ in
        return "ok"
    }
}

