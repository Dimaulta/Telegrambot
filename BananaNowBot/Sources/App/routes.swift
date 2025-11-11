import Vapor

func routes(_ app: Application) throws {
    let controller = BananaNowBotController()

    app.post("webhook") { req async throws in
        try await controller.handleWebhook(req)
    }

    app.post("banananow", "webhook") { req async throws in
        try await controller.handleWebhook(req)
    }

    app.get("health") { _ in
        "ok"
    }
}


