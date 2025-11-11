import Vapor

func routes(_ app: Application) throws {
    let controller = NeurfotobotController()
    app.post("webhook", use: controller.handleWebhook)
    // Дополнительный путь для проксирования через nginx/балансировщик
    app.post("neurfoto", "webhook", use: controller.handleWebhook)
    app.get("health") { _ in
        "ok"
    }
} 