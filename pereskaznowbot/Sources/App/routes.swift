import Vapor

func routes(_ app: Application) throws {
    let controller = PereskazNowBotController()
    app.post("webhook", use: controller.handleWebhook)
    // Дополнительный путь для проксирования через nginx/балансировщик
    app.post("pereskaznow", "webhook", use: controller.handleWebhook)
    app.get("health") { _ in
        return "ok"
    }
}
