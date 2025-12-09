import Vapor
import Foundation
import Fluent
import FluentSQLiteDriver

func getPortFromConfig(serviceName: String) -> Int {
    let configPath = "config/services.json"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let services = json["services"] as? [String: Any],
          let service = services[serviceName] as? [String: Any],
          let urlString = service["url"] as? String,
          let url = URL(string: urlString),
          let port = url.port else {
        return 8089 // fallback
    }
    return port
}

public func configure(_ app: Application) async throws {
    // Загружаем config/.env, чтобы подтянуть CONTENTFABRIKABOT_TOKEN и прочие ключи заранее
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
        app.logger.info("Loaded config/.env with \(vars.count) keys for ContentFabrikaBot")
    } else {
        app.logger.warning("config/.env not found while configuring ContentFabrikaBot — using process environment only")
    }

    // Настройка базы данных SQLite
    let dbPath = "contentfabrikabot/db.sqlite"
    app.databases.use(.sqlite(.file(dbPath)), as: .sqlite)

    // Добавление миграций
    app.migrations.add(CreateChannel())
    app.migrations.add(CreateStyleProfile())
    app.migrations.add(CreateChannelPost())

    // Автоматический запуск миграций
    try await app.autoMigrate()

    // Инициализация базы данных монетизации
    MonetizationService.ensureDatabase(app: app)

    // Получаем порт из общего конфига сервисов
    let port = getPortFromConfig(serviceName: "contentfabrikabot")
    app.http.server.configuration.port = port

    // Middleware для логирования всех входящих запросов (для диагностики webhook)
    app.middleware.use(LoggingMiddleware())

    app.logger.info("ContentFabrikaBot configured on port \(port)")

    try routes(app)
}

