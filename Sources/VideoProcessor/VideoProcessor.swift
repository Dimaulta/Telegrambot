import Vapor
import Foundation

public struct VideoProcessor {
    public init() {}
    
    public static func downloadAndProcess(fileId: String, chatId: String, req: Request) -> EventLoopFuture<Response> {
        let botToken = "7901916114:AAEAXDcoWhYqq5Wx4TAw1RUaxWxGaXWgf-k"
        let getFileUrl = "https://api.telegram.org/bot\(botToken)/getFile?file_id=\(fileId)"
        
        req.logger.info("Начинаем процесс обработки видео. FileId: \(fileId), ChatId: \(chatId)")
        req.logger.info("Запрашиваем информацию о файле по URL: \(getFileUrl)")

        return req.client.get(URI(string: getFileUrl)).flatMapThrowing { res in
            req.logger.info("Получен ответ от getFile API")
            let fileResponse = try res.content.decode(TelegramFileResponse.self)
            req.logger.info("Декодирован ответ от Telegram API: \(fileResponse)")
            let filePath = fileResponse.result.file_path
            let downloadUrl = "https://api.telegram.org/file/bot\(botToken)/\(filePath)"
            req.logger.info("URL для скачивания видео: \(downloadUrl)")

            return try processVideo(downloadUrl: downloadUrl, req: req)
        }.flatMap { processedFilePath in
            req.logger.info("Видео обработано, путь к обработанному файлу: \(processedFilePath)")
            return sendProcessedVideo(processedFilePath, chatId: chatId, req: req)
        }
    }

    private static func processVideo(downloadUrl: String, req: Request) throws -> String {
        let fileManager = FileManager.default
        let currentDirectory = fileManager.currentDirectoryPath
        let tempDirectory = "\(currentDirectory)/temporaryvideoFiles"
        
        // Создаем временную директорию, если её нет
        if !fileManager.fileExists(atPath: tempDirectory) {
            try fileManager.createDirectory(atPath: tempDirectory, withIntermediateDirectories: true)
            req.logger.info("Создана директория для временных файлов: \(tempDirectory)")
        }
        
        // Генерируем уникальные имена файлов с временной меткой
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = dateFormatter.string(from: Date())
        let uniqueId = UUID().uuidString.prefix(8)
        
        let inputFilePath = "\(tempDirectory)/input_\(timestamp)_\(uniqueId).mp4"
        let outputFilePath = "\(tempDirectory)/output_\(timestamp)_\(uniqueId).mp4"

        req.logger.info("Начинаем скачивание видео...")
        req.logger.info("Путь для входного файла: \(inputFilePath)")
        req.logger.info("Путь для выходного файла: \(outputFilePath)")

        // Скачиваем видео
        req.logger.info("Скачиваем видео по URL: \(downloadUrl)")
        let videoData = try Data(contentsOf: URL(string: downloadUrl)!)
        try videoData.write(to: URL(fileURLWithPath: inputFilePath))

        req.logger.info("Видео скачано по пути: \(inputFilePath)")

        // Проверяем размер файла
        let fileSize = try fileManager.attributesOfItem(atPath: inputFilePath)[.size] as? Int ?? 0
        req.logger.info("Размер видео: \(fileSize) байт")
        if fileSize > 50 * 1024 * 1024 { // 50MB — лимит Telegram
            // Удаляем временные файлы при ошибке
            try? fileManager.removeItem(atPath: inputFilePath)
            req.logger.error("Файл слишком большой: \(fileSize) байт")
            throw Abort(.badRequest, reason: "Файл слишком большой!")
        }

        // Проверяем длительность видео
        let duration = getVideoDuration(inputFilePath)
        req.logger.info("Длительность видео: \(duration) секунд")
        if duration > 59 {
            // Удаляем временные файлы при ошибке
            try? fileManager.removeItem(atPath: inputFilePath)
            req.logger.error("Видео слишком длинное: \(duration) секунд")
            throw Abort(.badRequest, reason: "Видео длиннее 59 секунд!")
        }

        // Конвертируем в видеокружок
        req.logger.info("Начинаем обработку видео через ffmpeg...")
        req.logger.info("Команда ffmpeg: ffmpeg -i \(inputFilePath) -vf scale=240:240,format=yuv420p -t 59 -metadata:s:v rotate=0 -b:v 256k -preset fast -y \(outputFilePath)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = [
            "-i", inputFilePath,
            "-vf", "scale=240:240,format=yuv420p",
            "-t", "59",
            "-metadata:s:v", "rotate=0",
            "-b:v", "256k",
            "-preset", "fast",
            "-y", outputFilePath
        ]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            // Удаляем временные файлы при ошибке
            try? fileManager.removeItem(atPath: inputFilePath)
            try? fileManager.removeItem(atPath: outputFilePath)
            
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let outputString = String(data: outputData, encoding: .utf8) ?? "Нет вывода"
            req.logger.error("Ошибка при обработке видео через ffmpeg. Код: \(process.terminationStatus), Вывод: \(outputString)")
            throw Abort(.internalServerError, reason: "Ошибка при обработке видео через ffmpeg")
        }

        // Удаляем входной файл, так как он больше не нужен
        try? fileManager.removeItem(atPath: inputFilePath)

        req.logger.info("Видео успешно обработано и сохранено по пути: \(outputFilePath)")
        return outputFilePath
    }

    private static func getVideoDuration(_ filePath: String) -> Int {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
        process.arguments = [
            "-i", filePath,
            "-show_entries", "format=duration",
            "-v", "quiet",
            "-of", "csv=p=0"
        ]
        process.standardOutput = pipe

        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let durationString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(Double(durationString ?? "0") ?? 0)
    }

    private static func sendProcessedVideo(_ filePath: String, chatId: String, req: Request) -> EventLoopFuture<Response> {
        let botToken = "7901916114:AAEAXDcoWhYqq5Wx4TAw1RUaxWxGaXWgf-k"
        let url = URI(string: "https://api.telegram.org/bot\(botToken)/sendVideo")

        req.logger.info("Читаем файл перед отправкой...")
        let videoData = try! Data(contentsOf: URL(fileURLWithPath: filePath))
        req.logger.info("Размер обработанного видео: \(videoData.count) байт")

        var headers = HTTPHeaders()
        headers.contentType = .formData

        let boundary = UUID().uuidString
        req.logger.info("Создаем multipart/form-data с boundary: \(boundary)")
        
        var body = ByteBufferAllocator().buffer(capacity: videoData.count + 1024)

        // Добавляем параметры
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n")
        body.writeString("\(chatId)\r\n")
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"supports_streaming\"\r\n\r\n")
        body.writeString("true\r\n")

        // Добавляем видео
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"video\"; filename=\"video.mp4\"\r\n")
        body.writeString("Content-Type: video/mp4\r\n\r\n")
        body.writeBytes(videoData)
        body.writeString("\r\n")
        body.writeString("--\(boundary)--\r\n")

        req.logger.info("Подготовили тело запроса, размер: \(body.readableBytes) байт")
        req.logger.info("Отправляем видео в Telegram...")
        
        return req.client.post(url, headers: headers) { post in
            post.body = body
        }.map { clientResponse in
            req.logger.info("Получен ответ от Telegram API. Статус: \(clientResponse.status)")
            if let responseBody = clientResponse.body {
                req.logger.info("Тело ответа: \(String(buffer: responseBody))")
            }
            
            // Удаляем выходной файл после отправки
            try? FileManager.default.removeItem(atPath: filePath)
            req.logger.info("Временный файл удален: \(filePath)")
            
            return Response(status: clientResponse.status, headers: clientResponse.headers, body: Response.Body(buffer: clientResponse.body ?? ByteBuffer()))
        }.flatMapError { error in
            req.logger.error("Ошибка при отправке видео: \(error)")
            // Удаляем выходной файл в случае ошибки
            try? FileManager.default.removeItem(atPath: filePath)
            req.logger.info("Временный файл удален после ошибки: \(filePath)")
            return req.eventLoop.makeFailedFuture(error)
        }
    }
}