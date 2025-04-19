import Vapor

struct NgrokMiddleware: Middleware {
    func respond(to request: Request, chainingTo next: Responder) -> EventLoopFuture<Response> {
        return next.respond(to: request).map { response in
            response.headers.add(name: "ngrok-skip-browser-warning", value: "true")
            return response
        }
    }
} 