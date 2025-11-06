import Vapor

func routes(_ app: Application) throws {
    let controller = SoranowBotController()
    // Поддерживаем оба пути: /webhook и /sora/webhook (для nginx проксирования)
    app.post("webhook", use: controller.handleWebhook)
    app.post("sora", "webhook", use: controller.handleWebhook)
    app.get("health") { _ in
        return "ok"
    }
}
