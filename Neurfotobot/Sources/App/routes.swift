import Vapor

func routes(_ app: Application) throws {
    let controller = SecondBotController()
    app.post("webhook", use: controller.handleWebhook)
} 