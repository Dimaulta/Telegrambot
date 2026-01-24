import Vapor

func routes(_ app: Application) throws {
    let controller = FileNowBotController()
    app.post("webhook", use: controller.handleWebhook)
    // Дополнительный путь для проксирования через nginx/балансировщик
    app.post("filenow", "webhook", use: controller.handleWebhook)
    app.get("health") { _ in
        return "ok"
    }
}

