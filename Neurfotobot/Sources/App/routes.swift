import Vapor

func routes(_ app: Application) throws {
    let controller = NeurfotobotController()
    app.post("webhook", use: controller.handleWebhook)
} 