import Vapor

func routes(_ app: Application) throws {
    let controller = TelegramBot03Controller()
    app.post("webhook", use: controller.handleWebhook)
}
