import Vapor

func routes(_ app: Application) throws {
    let controller = ContentFabrikaBotController()
    
    app.post("webhook") { req async throws in
        req.logger.info("📥 Received webhook request on /webhook")
        return try await controller.handleWebhook(req)
    }
    
    // Дополнительный путь для проксирования через nginx/балансировщик
    app.post("contentfabrika", "webhook") { req async throws in
        req.logger.info("📥 Received webhook request on /contentfabrika/webhook")
        return try await controller.handleWebhook(req)
    }
    
    app.get("health") { req in
        req.logger.info("🏥 Health check")
        return "ok"
    }
}

