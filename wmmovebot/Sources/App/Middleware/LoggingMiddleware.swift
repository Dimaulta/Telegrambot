import Vapor

struct LoggingMiddleware: Middleware {
    func respond(to request: Request, chainingTo next: Responder) -> EventLoopFuture<Response> {
        // Логируем все POST запросы (особенно webhook'и от Telegram)
        if request.method == .POST {
            let path = request.url.path
            let bodyLength = request.body.string?.count ?? 0
            request.logger.info("🌐 INCOMING POST: \(path) | Body length: \(bodyLength) bytes")
            
            // Для webhook'ов логируем первые 200 символов тела
            if path.contains("webhook") && bodyLength > 0 {
                let bodyPreview = request.body.string?.prefix(200) ?? ""
                request.logger.info("📦 Webhook body preview: \(bodyPreview)")
            }
        }
        
        return next.respond(to: request)
    }
}

