import Foundation
import Vapor

/// Вспомогательные функции для работы с временной директорией Neurfotobot.
enum NeurfotobotTempDirectory {
    /// Возвращает базовый URL временной директории Neurfotobot.
    /// Путь берётся из NEURFOTOBOT_TEMP_DIR или по умолчанию "Neurfotobot/tmp".
    /// Гарантирует, что директория существует.
    static func baseURL() throws -> URL {
        let fileManager = FileManager.default

        let rawPath = Environment.get("NEURFOTOBOT_TEMP_DIR")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String

        if let rawPath, !rawPath.isEmpty {
            path = rawPath
        } else {
            path = "Neurfotobot/tmp"
        }

        let url = URL(fileURLWithPath: path, isDirectory: true)
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// Строит полный путь до файла относительно базовой директории.
    static func fileURL(relativePath: String) throws -> URL {
        let base = try baseURL()
        return base.appendingPathComponent(relativePath)
    }
}


