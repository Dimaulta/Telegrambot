import Vapor
import Foundation
import AsyncHTTPClient
import NIOSSL

func getPortFromConfig(serviceName: String) -> Int {
    let configPath = "config/services.json"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let services = json["services"] as? [String: Any],
          let service = services[serviceName] as? [String: Any],
          let urlString = service["url"] as? String,
          let url = URL(string: urlString),
          let port = url.port else {
        return 8090 // fallback
    }
    return port
}

public func configure(_ app: Application) async throws {
    // Загружаем config/.env и применяем переменные окружения
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
        app.logger.info("Loaded config/.env with \(vars.count) keys for PereskazNowBot")
    }

    let port = getPortFromConfig(serviceName: "pereskaznowbot")
    app.http.server.configuration.port = port
    
    // Настройка HTTP клиента: connect 60s, read 600s для Whisper API
    app.http.client.configuration.timeout = .init(connect: .seconds(60), read: .seconds(600))
    app.http.client.configuration.connectionPool.idleTimeout = .seconds(60)
    
    // SaluteSpeech TLS (fallback при сбоях Whisper)
    configureSaluteSpeechTLS(app)
    
    MonetizationService.ensureDatabase(app: app)
    
    try routes(app)
}

private func configureSaluteSpeechTLS(_ app: Application) {
    let defaultPath = "config/certs/salutespeech-chain.pem"
    let path = Environment.get("SALUTESPEECH_CA_PATH") ?? defaultPath
    
    guard FileManager.default.fileExists(atPath: path) else {
        app.logger.info("SaluteSpeech TLS: сертификат не найден (\(path)). Fallback SaluteSpeech может не работать.")
        return
    }
    
    do {
        let certificates = try NIOSSLCertificate.fromPEMFile(path)
        guard certificates.isEmpty == false else {
            app.logger.warning("SaluteSpeech TLS: файл \(path) не содержит сертификатов.")
            return
        }
        
        var clientConfig = app.http.client.configuration
        var tlsConfig = clientConfig.tlsConfiguration ?? TLSConfiguration.makeClientConfiguration()
        tlsConfig.additionalTrustRoots.append(.certificates(certificates))
        clientConfig.tlsConfiguration = tlsConfig
        app.http.client.configuration = clientConfig
        app.logger.info("SaluteSpeech TLS: добавлены корневые сертификаты из \(path)")
    } catch {
        app.logger.error("SaluteSpeech TLS: не удалось загрузить сертификаты из \(path): \(error.localizedDescription)")
    }
}
