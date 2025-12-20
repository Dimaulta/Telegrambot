import Vapor
import Foundation
#if canImport(Darwin)
import Darwin
#endif
// MonetizationService lives in the same module

func getPortFromConfig(serviceName: String) async throws -> Int {
    let configPath = "config/services.json"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let services = json["services"] as? [String: Any],
          let service = services[serviceName] as? [String: Any],
          let urlString = service["url"] as? String,
          let url = URL(string: urlString),
          let port = url.port else {
        return 8081 // fallback
    }
    return port
}

public func configure(_ app: Application) async throws {
    // Загружаем config/.env и применяем в окружение процесса (для VIDEO_BOT_TOKEN)
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
        app.logger.info("Loaded config/.env with \(vars.count) keys for VideoService")
    }
    // Инициализируем базу монетизации (не влияет на основную работу при ошибках)
    MonetizationService.ensureDatabase(app: app)

    // Получаем порт из конфига
    let port = try await getPortFromConfig(serviceName: "video-processing")
    app.http.server.configuration.port = port

    // Настраиваем маршруты
    try await routes(app)

    // Кастомный путь к папке Public для этого видеосервиса
    app.directory.publicDirectory = app.directory.workingDirectory + "Roundsvideobot/VideoService/Public/"

    // Добавь FileMiddleware для отдачи статики
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // Увеличиваем лимит на размер загружаемого файла
    app.routes.defaultMaxBodySize = "100mb"
    
    // Создаем папку для временных файлов если её нет
    let tempDir = "Roundsvideobot/Resources/temporaryvideoFiles"
    if !FileManager.default.fileExists(atPath: tempDir) {
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        app.logger.info("Создана папка для временных файлов: \(tempDir)")
    }
} 