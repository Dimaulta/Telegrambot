import Vapor

func routes(_ app: Application) throws {
    app.get("health") { _ in
        "ok"
    }

    app.post("webhook") { req async throws -> Response in
        try await GolosNowBotController().handleWebhook(req)
    }

    app.post("veonow", "webhook") { req async throws -> Response in
        try await GolosNowBotController().handleWebhook(req)
    }
}

