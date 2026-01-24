import Vapor

func routes(_ app: Application) throws {
    let controller = GolosNowBotController(app: app)
    app.post("webhook", use: controller.handleWebhook)
    // Поддерживаем полный путь для Traefik
    app.post("golosnow", "webhook", use: controller.handleWebhook)
}
