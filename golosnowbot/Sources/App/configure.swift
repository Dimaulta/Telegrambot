import Vapor
import Foundation

private func loadEnvironmentVariables(logger: Logger) {
    let envPath = "golosnowbot/config/.env"
    guard let content = try? String(contentsOfFile: envPath, encoding: .utf8) else {
        logger.warning(".env file not found at \(envPath). Skipping environment loading.")
        return
    }

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
    logger.info("Loaded \(vars.count) environment variables for GolosNowBot")
}

private func getPortFromConfig(serviceName: String) -> Int? {
    let configPath = "config/services.json"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let services = json["services"] as? [String: Any],
          let service = services[serviceName] as? [String: Any],
          let urlString = service["url"] as? String,
          let url = URL(string: urlString),
          let port = url.port else {
        return nil
    }
    return port
}

public func configure(_ app: Application) async throws {
    loadEnvironmentVariables(logger: app.logger)

    let configuredPort = Environment.get("GOLOSNOWBOT_PORT").flatMap(Int.init)
        ?? getPortFromConfig(serviceName: "golosnowbot")
        ?? 8087
    app.http.server.configuration.port = configuredPort

    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
    app.middleware.use(CORSMiddleware(configuration: .default()))

    try routes(app)
}

