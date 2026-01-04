import Vapor

func routes(_ app: Application) throws {
    let controller = AntispamNowBotController()

    app.post("webhook") { req async throws in
        try await controller.handleWebhook(req)
    }

    app.post("antispamnow", "webhook") { req async throws in
        try await controller.handleWebhook(req)
    }

    app.get("health") { _ in
        "ok"
    }
}


