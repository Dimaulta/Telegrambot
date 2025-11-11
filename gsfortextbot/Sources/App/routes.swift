import Vapor

func routes(_ app: Application) throws {
    let controller = GSForTextBotController(app: app)
    app.post("webhook", use: controller.handleWebhook)
}
