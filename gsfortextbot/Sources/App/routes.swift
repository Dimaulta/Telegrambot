import Vapor

func routes(_ app: Application) throws {
    let controller = GSForTextBotController()
    app.post("webhook", use: controller.handleWebhook)
}
