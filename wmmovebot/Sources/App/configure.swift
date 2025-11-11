import Vapor
import Foundation
import AsyncHTTPClient

func getPortFromConfig(serviceName: String) -> Int {
    let configPath = "config/services.json"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let services = json["services"] as? [String: Any],
          let service = services[serviceName] as? [String: Any],
          let urlString = service["url"] as? String,
          let url = URL(string: urlString),
          let port = url.port else {
        return 8084 // fallback
    }
    return port
}

public func configure(_ app: Application) async throws {
    // Загружаем config/.env и применяем переменные окружения (для WMMOVEBOT_TOKEN)
    let envPath = "config/.env"
    if let content = try? String(contentsOfFile: envPath) {
        var vars: [String: String] = [:]
        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                vars[String(parts[0])] = String(parts[1])
            }
        }
        for (k, v) in vars { setenv(k, v, 1) }
        app.logger.info("Loaded config/.env with \(vars.count) keys for WmmoveBot")
    }

    let port = getPortFromConfig(serviceName: "wmmovebot")
    app.http.server.configuration.port = port
    
    // Middleware для логирования всех входящих запросов (для диагностики webhook)
    app.middleware.use(LoggingMiddleware())

    // Опциональная поддержка HTTP-прокси для исходящих запросов (чтобы обойти геоблок)
    // Задай переменную окружения SORA_HTTP_PROXY в формате: http://host:port
    if let proxyStr = Environment.get("SORA_HTTP_PROXY"),
       let proxyURL = URL(string: proxyStr),
       let host = proxyURL.host, let port = proxyURL.port {
        var cfg = app.http.client.configuration
        // Базовая авторизация (опционально): SORA_PROXY_USER / SORA_PROXY_PASS
        if let user = Environment.get("SORA_PROXY_USER"), let pass = Environment.get("SORA_PROXY_PASS") {
            cfg.proxy = .server(host: host, port: port, authorization: .basic(username: user, password: pass))
        } else {
            cfg.proxy = .server(host: host, port: port)
        }
        app.http.client.configuration = cfg
        app.logger.info("WmmoveBot HTTP proxy enabled: \(host):\(port)")
    }

    try routes(app)
}
