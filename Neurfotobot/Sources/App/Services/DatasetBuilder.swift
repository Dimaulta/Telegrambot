import Vapor
import Foundation
import ZIPFoundation

struct DatasetBuilder {
    struct Result {
        let datasetPath: String
        let publicURL: String
    }

    private let storage: SupabaseStorageClient
    private let logger: Logger

    init(application: Application, logger: Logger) throws {
        self.storage = try SupabaseStorageClient(application: application)
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
            let data = try await storage.download(path: photo.path)
            let ext = (photo.path as NSString).pathExtension
            let filename = String(format: "%02d.%@", index + 1, ext.isEmpty ? "jpg" : ext)
            let localURL = tempDirectory.appendingPathComponent(filename)
            try data.write(to: localURL)
            localFiles.append(localURL)
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

        let archiveData = try Data(contentsOf: archiveURL)
        var buffer = ByteBufferAllocator().buffer(capacity: archiveData.count)
        buffer.writeBytes(archiveData)

        let datasetPath = "datasets/\(chatId)/dataset.zip"
        _ = try await storage.upload(path: datasetPath, data: buffer, contentType: "application/zip", upsert: true)
        let publicURL = storage.publicURL(for: datasetPath)

        logger.info("Dataset for chatId=\(chatId) uploaded to Supabase at path=\(datasetPath)")
        logger.info("Dataset public URL for chatId=\(chatId): \(publicURL)")

        return Result(datasetPath: datasetPath, publicURL: publicURL)
    }

    func deleteDataset(at path: String) async {
        do {
            try await storage.delete(path: path)
        } catch {
            logger.warning("Failed to delete dataset at \(path): \(error)")
        }
    }
}

