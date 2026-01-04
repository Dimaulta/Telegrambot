import Vapor
import Foundation

private func getPortFromConfig(serviceName: String) -> Int {
    let configPath = "config/services.json"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let services = json["services"] as? [String: Any],
          let service = services[serviceName] as? [String: Any],
          let urlString = service["url"] as? String,
          let url = URL(string: urlString),
          let port = url.port else {
        return 8086
    }
    return port
}

private func loadDotEnvIfAvailable(logger: Logger) {
    let envPath = "config/.env"
    guard let content = try? String(contentsOfFile: envPath) else {
        logger.debug("config/.env not found for NeurVideoBot")
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
    logger.info("Loaded config/.env with \(vars.count) keys for NeurVideoBot")
}

public func configure(_ app: Application) async throws {
    loadDotEnvIfAvailable(logger: app.logger)

    let port = getPortFromConfig(serviceName: "NeurVideoBot")
    app.http.server.configuration.port = port

    if let proxyString = Environment.get("NEURVIDEOBOT_HTTP_PROXY"),
       let proxyURL = URL(string: proxyString),
       let host = proxyURL.host,
       let port = proxyURL.port {
        var configuration = app.http.client.configuration
        if let user = Environment.get("NEURVIDEOBOT_PROXY_USER"),
           let password = Environment.get("NEURVIDEOBOT_PROXY_PASS") {
            configuration.proxy = .server(
                host: host,
                port: port,
                authorization: .basic(username: user, password: password)
            )
        } else {
            configuration.proxy = .server(host: host, port: port)
        }
        app.http.client.configuration = configuration
        app.logger.info("NeurVideoBot HTTP proxy enabled: \(host):\(port)")
    }

    try routes(app)
}

