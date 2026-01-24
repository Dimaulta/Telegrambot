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
        return 8085 // fallback
    }
    return port
}

public func configure(_ app: Application) async throws {
    // Загружаем config/.env и применяем переменные окружения (для FILENOWBOT_TOKEN)
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
        app.logger.info("Loaded config/.env with \(vars.count) keys for FileNowBot")
    }

    let port = getPortFromConfig(serviceName: "filenowbot")
    app.http.server.configuration.port = port
    
    // Инициализация базы данных монетизации
    MonetizationService.ensureDatabase(app: app)
    
    // Middleware для логирования всех входящих запросов
    app.middleware.use(LoggingMiddleware())

    try routes(app)
}

