import Foundation
import Vapor
import Darwin

struct Service: Codable {
    let url: String
    let routes: [String]
    let enabled: Bool
    let webhook_url: String
}

struct ServicesConfig: Codable {
    let services: [String: Service]
}

struct ServerConfig: Codable {
    let server: ServerDetails
}

struct ServerDetails: Codable {
    let ip: String
    let port: Int
    let protocolType: String
    let base_url: String
    
    enum CodingKeys: String, CodingKey {
        case ip, port, protocolType = "protocol", base_url
    }
}

func loadServicesConfig() throws -> ServicesConfig {
    let path = "config/services.json"
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try JSONDecoder().decode(ServicesConfig.self, from: data)
}

func loadServerConfig() throws -> ServerConfig {
    let path = "config/server.json"
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try JSONDecoder().decode(ServerConfig.self, from: data)
}

func loadEnv() -> [String: String] {
    let path = "config/.env"
    guard let content = try? String(contentsOfFile: path) else { return [:] }
    var dict: [String: String] = [:]
    for line in content.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        let parts = trimmed.split(separator: "=", maxSplits: 1)
        if parts.count == 2 {
            dict[String(parts[0])] = String(parts[1])
        }
    }
    return dict
} 

/// Применяет пары ключ-значение в текущем процессе как переменные окружения
func applyEnv(_ vars: [String: String]) {
    for (key, value) in vars {
        setenv(key, value, 1)
    }
}