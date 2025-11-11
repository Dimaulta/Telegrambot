import Vapor
import Foundation

func getPortFromConfig(serviceName: String) -> Int {
    let configPath = "config/services.json"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let services = json["services"] as? [String: Any],
          let service = services[serviceName] as? [String: Any],
          let urlString = service["url"] as? String,
          let url = URL(string: urlString),
          let port = url.port else {
        return 8082 // fallback
    }
    return port
}

public func configure(_ app: Application) async throws {
    // Загружаем config/.env, чтобы подтянуть NEURFOTOBOT_TOKEN и прочие ключи заранее
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
        for (key, value) in vars {
            setenv(key, value, 1)
        }
        app.logger.info("Loaded config/.env with \(vars.count) keys for Neurfotobot")
    } else {
        app.logger.warning("config/.env not found while configuring Neurfotobot — using process environment only")
    }

    // Получаем порт из общего конфига сервисов
    let port = getPortFromConfig(serviceName: "Neurfotobot")
    app.http.server.configuration.port = port

    // Включаем базовое логирование запросов (полезно на этапе интеграции)
    app.middleware.use(RequestLoggerMiddleware(logLevel: .info))

    try routes(app)
}