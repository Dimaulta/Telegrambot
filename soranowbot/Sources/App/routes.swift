import Vapor

func routes(_ app: Application) throws {
    app.post("webhook") { req async throws in
        try await SoranowBotController().handleWebhook(req)
    }

    app.post("soranow", "webhook") { req async throws in
        try await SoranowBotController().handleWebhook(req)
    }

    app.get("health") { _ in
        "ok"
    }
}

