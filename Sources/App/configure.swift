import NIOSSL
import Fluent
import FluentSQLiteDriver
import Vapor

// Определяем ключи для хранения
struct IsProcessingKey: StorageKey {
    typealias Value = Bool
}

struct ResourcesPathKey: StorageKey {
    typealias Value = String
}

struct TemporaryPathKey: StorageKey {
    typealias Value = String
}

// configures your application
public func configure(_ app: Application) async throws {
    // Configure CORS
    let corsConfiguration = CORSMiddleware.Configuration(
        allowedOrigin: .all,
        allowedMethods: [.GET, .POST, .PUT, .OPTIONS, .DELETE, .PATCH],
        allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith, .userAgent, .accessControlAllowOrigin, .init("ngrok-skip-browser-warning")]
    )
    let cors = CORSMiddleware(configuration: corsConfiguration)
    app.middleware.use(cors)
    
    // uncomment to serve files from /Public folder
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // Настройка базы данных SQLite
    app.databases.use(DatabaseConfigurationFactory.sqlite(.file("db.sqlite")), as: .sqlite)

    // Добавление миграций
    app.migrations.add(CreateTodo())

    // Настройка сервера (хост и порт)
    app.http.server.configuration.hostname = "0.0.0.0"
    app.http.server.configuration.port = 8080

    // Создание папки для временных файлов с использованием относительного пути
    let resourcesPath = "Resources"
    let temporaryDirName = "temporaryvideoFiles"
    let temporaryPath = "\(resourcesPath)/\(temporaryDirName)"
    
    // Убеждаемся, что директория Resources существует
    if !FileManager.default.fileExists(atPath: resourcesPath) {
        try FileManager.default.createDirectory(atPath: resourcesPath, withIntermediateDirectories: true)
    }
    
    // Убеждаемся, что директория для временных файлов существует
    if !FileManager.default.fileExists(atPath: temporaryPath) {
        try FileManager.default.createDirectory(atPath: temporaryPath, withIntermediateDirectories: true)
    }

    app.logger.info("Путь к ресурсам: \(resourcesPath)")
    app.logger.info("Временная директория: \(temporaryPath)")

    // Сохраняем пути в storage для использования в других частях приложения
    app.storage.set(ResourcesPathKey.self, to: resourcesPath)
    app.storage.set(TemporaryPathKey.self, to: temporaryPath)

    // Инициализация isProcessing в Application.storage
    await app.storage.setWithAsyncShutdown(IsProcessingKey.self, to: false)
    app.logger.info("Инициализировано isProcessing: \(app.isProcessing)")

    // Настройка максимального размера тела запроса (100 МБ)
    app.routes.defaultMaxBodySize = "100mb"
    
    // register routes
    try routes(app)
}

// Расширение для удобного доступа к isProcessing
extension Application {
    var isProcessing: Bool {
        get {
            return self.storage.get(IsProcessingKey.self) ?? false
        }
        set {
            self.storage.set(IsProcessingKey.self, to: newValue)
        }
    }
    
    // Добавляем удобные геттеры для путей
    var resourcesPath: String {
        return self.storage.get(ResourcesPathKey.self) ?? "Resources"
    }
    
    var temporaryPath: String {
        return self.storage.get(TemporaryPathKey.self) ?? "Resources/temporaryvideoFiles"
    }
}