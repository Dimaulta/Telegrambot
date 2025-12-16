import Vapor
import Foundation
import ZIPFoundation

struct DatasetBuilder {
    struct Result {
        let datasetPath: String
        let publicURL: String
    }

    private let logger: Logger

    init(application: Application, logger: Logger) throws {
        self.logger = logger
    }

    func buildDataset(for chatId: Int64, photos: [PhotoSessionManager.PhotoRecord]) async throws -> Result {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("neurfoto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        var localFiles: [URL] = []
        for (index, photo) in photos.enumerated() {
            let sourceURL = try NeurfotobotTempDirectory.fileURL(relativePath: photo.path)
            let ext = (photo.path as NSString).pathExtension
            let filename = String(format: "%02d.%@", index + 1, ext.isEmpty ? "jpg" : ext)
            let localURL = tempDirectory.appendingPathComponent(filename)
            do {
                let data = try Data(contentsOf: sourceURL)
                try data.write(to: localURL)
                localFiles.append(localURL)
            } catch {
                logger.warning("Failed to copy photo \(photo.path) for dataset of chatId=\(chatId): \(error)")
            }
        }

        let archiveURL = tempDirectory.appendingPathComponent("dataset.zip")
        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .create)
        } catch {
            throw Abort(.internalServerError, reason: "Failed to create archive: \(error)")
        }

        for file in localFiles {
            try archive.addEntry(with: file.lastPathComponent, fileURL: file, compressionMethod: .deflate)
        }

        // Сохраняем архив в локальной директории NEURFOTOBOT_TEMP_DIR/datasets/{chatId}/dataset.zip
        let relativeDatasetPath = "datasets/\(chatId)/dataset.zip"
        let datasetURL = try NeurfotobotTempDirectory.fileURL(relativePath: relativeDatasetPath)
        let datasetDir = datasetURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: datasetDir, withIntermediateDirectories: true)

        let archiveData = try Data(contentsOf: archiveURL)
        try archiveData.write(to: datasetURL)

        // Формируем публичный URL через BASE_URL
        guard let baseURLRaw = Environment.get("BASE_URL"), !baseURLRaw.isEmpty else {
            throw Abort(.internalServerError, reason: "BASE_URL is not set")
        }
        var base = baseURLRaw
        if base.hasSuffix("/") {
            base.removeLast()
        }
        // Путь сервинга: /neurfotobot/datasets/{chatId}/dataset.zip
        let publicURL = "\(base)/neurfotobot/\(relativeDatasetPath)"

        logger.info("Dataset for chatId=\(chatId) built at local path=\(relativeDatasetPath)")
        logger.info("Dataset public URL for chatId=\(chatId): \(publicURL)")

        return Result(datasetPath: relativeDatasetPath, publicURL: publicURL)
    }

    func deleteDataset(at path: String) async {
        do {
            let url = try NeurfotobotTempDirectory.fileURL(relativePath: path)
            try FileManager.default.removeItem(at: url)
            logger.info("Deleted local dataset at \(path)")
        } catch {
            logger.warning("Failed to delete local dataset at \(path): \(error)")
        }
    }
}

