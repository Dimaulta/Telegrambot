import Vapor
import NIOSSL
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
        return 8083 // fallback
    }
    return port
}

public func configure(_ app: Application) async throws {
    let port = getPortFromConfig(serviceName: "gsfortextbot")
    app.http.server.configuration.port = port
    configureSaluteSpeechTLS(app)
    MonetizationService.ensureDatabase(app: app)
    try routes(app)
}

private func configureSaluteSpeechTLS(_ app: Application) {
    let defaultPath = "config/certs/salutespeech-chain.pem"
    let path = Environment.get("SALUTESPEECH_CA_PATH") ?? defaultPath
    
    guard FileManager.default.fileExists(atPath: path) else {
        app.logger.info("SaluteSpeech TLS: сертификат не найден по пути \(path). Если хочешь доверять без Keychain, положи PEM сюда или укажи SALUTESPEECH_CA_PATH.")
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
        app.logger.info("SaluteSpeech TLS: добавлены дополнительные корневые сертификаты из \(path)")
    } catch {
        app.logger.error("SaluteSpeech TLS: не удалось загрузить сертификаты из \(path): \(error.localizedDescription)")
    }
}
