import NIOSSL
import Fluent
import FluentSQLiteDriver
import Vapor

// Определяем ключ для хранения isProcessing
struct IsProcessingKey: StorageKey {
    typealias Value = Bool
}

// configures your application
public func configure(_ app: Application) async throws {
    // uncomment to serve files from /Public folder
    // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // Настройка базы данных SQLite
    app.databases.use(DatabaseConfigurationFactory.sqlite(.file("db.sqlite")), as: .sqlite)

    // Добавление миграций
    app.migrations.add(CreateTodo())

    // Настройка сервера (хост и порт)
    app.http.server.configuration.hostname = "127.0.0.1"
    app.http.server.configuration.port = 8080

    // Создание папки для временных файлов
    let temporaryDir = "/Users/a1111/Desktop/projects/telegramBot01/temporaryvideoFiles"
    if !FileManager.default.fileExists(atPath: temporaryDir) {
        try FileManager.default.createDirectory(atPath: temporaryDir, withIntermediateDirectories: true)
    }

    // Инициализация isProcessing в Application.storage
    await app.storage.setWithAsyncShutdown(IsProcessingKey.self, to: false)
    app.logger.info("Инициализировано isProcessing: \(app.isProcessing)")

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
}