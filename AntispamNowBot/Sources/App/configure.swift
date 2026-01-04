import Vapor
import Foundation
import Logging

public func configure(_ app: Application) async throws {
    loadLocalEnv(into: app.logger)

    let port = resolvePort(logger: app.logger)
    app.http.server.configuration.port = port
    app.logger.info("AntispamNowBot слушает порт \(port)")

    try routes(app)
}

private func loadLocalEnv(into logger: Logger, path: String = "config/.env") {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
        logger.notice("config/.env не найден или недоступен — пропускаю загрузку переменных")
        return
    }

    var loaded = 0
    for line in contents.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("#") {
            continue
        }

        let parts = trimmed.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }

        let key = String(parts[0])
        let value = String(parts[1])
        setenv(key, value, 1)
        loaded += 1
    }

    logger.info("Загружено \(loaded) переменных окружения из config/.env для AntispamNowBot")
}

private func resolvePort(logger: Logger, defaultPort: Int = 8088) -> Int {
    if let fromEnv = Environment.get("ANTISPAMNOWBOT_PORT"), let value = Int(fromEnv) {
        logger.info("Использую порт из ANTISPAMNOWBOT_PORT=\(value)")
        return value
    }

    logger.notice("ANTISPAMNOWBOT_PORT не задан — применяю порт по умолчанию \(defaultPort)")
    return defaultPort
}


