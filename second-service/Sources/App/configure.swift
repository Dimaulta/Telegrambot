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
    // Получаем порт из конфига
    let port = getPortFromConfig(serviceName: "second-service")
    app.http.server.configuration.port = port

    // ... остальная конфигурация ...
    try routes(app)
} 