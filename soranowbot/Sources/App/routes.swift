import Vapor

func routes(_ app: Application) throws {
    let controller = SoranowBotController()
    app.post("webhook", use: controller.handleWebhook)
}
