import Vapor

func routes(_ app: Application) throws {
    app.post("webhook") { req async throws in
        try await NeurVideoBotController().handleWebhook(req)
    }

    app.post("soranow", "webhook") { req async throws in
        try await NeurVideoBotController().handleWebhook(req)
    }

    app.get("health") { _ in
        "ok"
    }
}

