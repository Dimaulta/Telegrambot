import Vapor

func routes(_ app: Application) throws {
    let controller = GSForTextBotController(app: app)
    app.post("webhook", use: controller.handleWebhook)
    // Поддерживаем полный путь для Traefik
    app.post("gs", "text", "webhook", use: controller.handleWebhook)
}
