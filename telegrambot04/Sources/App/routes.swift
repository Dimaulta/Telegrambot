import Vapor

func routes(_ app: Application) throws {
    let controller = TelegramBot04Controller()
    app.post("webhook", use: controller.handleWebhook)
}
