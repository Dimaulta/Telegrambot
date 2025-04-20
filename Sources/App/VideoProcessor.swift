import Vapor
import Foundation

struct VideoProcessor {
    let botToken: String
    let req: Request

    func downloadAndProcess(videoId: String, chatId: String) async throws {
        let temporaryDir = "\(req.application.directory.workingDirectory)temporaryvideoFiles"
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let uniqueId = UUID().uuidString.prefix(8)
        let inputPath = "\(temporaryDir)/input_\(timestamp)_\(uniqueId).mp4"
        let outputPath = "\(temporaryDir)/output_\(timestamp)_\(uniqueId).mp4"

        defer {
            // Удаляем временные файлы после обработки
            try? FileManager.default.removeItem(atPath: inputPath)
            try? FileManager.default.removeItem(atPath: outputPath)
            req.logger.info("Входной файл удалён после обработки: \(inputPath)")
            req.logger.info("Выходной файл удалён после обработки: \(outputPath)")
        }

        // Получаем информацию о файле
        let getFileUrl = URI(string: "https://api.telegram.org/bot\(botToken)/getFile?file_id=\(videoId)")
        req.logger.info("Запрашиваем информацию о файле по URL: \(getFileUrl)")

        let fileResponse = try await req.client.get(getFileUrl).flatMapThrowing { res -> TelegramFileResponse in
            req.logger.info("Получен ответ от getFile API. Статус: \(res.status)")
            guard res.status == HTTPStatus.ok, let body = res.body else {
                throw Abort(.badRequest, reason: "Не удалось получить информацию о файле")
            }
            let data = body.getData(at: 0, length: body.readableBytes) ?? Data()
            req.logger.info("Размер данных ответа getFile: \(data.count) байт")
            let response = try JSONDecoder().decode(TelegramFileResponse.self, from: data)
            req.logger.info("Успешно декодирован ответ: \(response)")
            return response
        }.get()

        req.logger.info("Декодирован ответ от Telegram API: \(fileResponse)")

        let filePath = fileResponse.result.file_path
        let downloadUrl = URI(string: "https://api.telegram.org/file/bot\(botToken)/\(filePath)")
        req.logger.info("URL для скачивания видео: \(downloadUrl)")

        // Скачиваем видео
        req.logger.info("Начинаем скачивание видео...")
        req.logger.info("Путь для входного файла: \(inputPath)")
        req.logger.info("Путь для выходного файла: \(outputPath)")

        req.logger.info("Скачиваем видео по URL: \(downloadUrl)")
        let downloadResponse = try await req.client.get(downloadUrl).get()
        guard downloadResponse.status == HTTPStatus.ok, let body = downloadResponse.body else {
            throw Abort(.badRequest, reason: "Не удалось скачать видео")
        }

        let videoData = body.getData(at: 0, length: body.readableBytes) ?? Data()
        try videoData.write(to: URL(fileURLWithPath: inputPath))
        req.logger.info("Видео успешно скачано по пути: \(inputPath)")
        req.logger.info("Размер видео: \(videoData.count) байт")

        // Проверяем размер файла
        let fileSize = videoData.count
        if fileSize > 50 * 1024 * 1024 { // 50 МБ
            throw Abort(.badRequest, reason: "Файл слишком большой (\(fileSize) байт). Максимальный размер — 50 МБ.")
        }

        // Проверяем длительность видео
        let duration = try await getVideoDuration(inputPath: inputPath)
        req.logger.info("Длительность видео: \(duration) секунд")

        // Обрабатываем видео с помощью FFmpeg
        req.logger.info("Начинаем обработку видео через ffmpeg...")
        let ffmpegCommand = "ffmpeg -i \(inputPath) -vf scale=640:640,format=yuv420p -t 59 -b:v 512k -r 30 -preset fast -movflags +faststart -y \(outputPath)"
        req.logger.info("Команда ffmpeg: \(ffmpegCommand)")

        let startTime = Date()
        req.logger.info("Время начала FFmpeg: \(startTime)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = [
            "-i", inputPath,
            "-vf", "scale=640:640,format=yuv420p",
            "-t", "59",
            "-b:v", "512k",
            "-r", "30",
            "-preset", "fast",
            "-movflags", "+faststart",
            "-y", outputPath
        ]

        let stderr = Pipe()
        process.standardError = stderr
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")

        try process.run()
        req.logger.info("Запускаем FFmpeg...")

        // Читаем stderr в реальном времени
        let stderrHandle = stderr.fileHandleForReading
        while process.isRunning {
            let data = stderrHandle.availableData
            if !data.isEmpty, let stderrOutput = String(data: data, encoding: .utf8) {
                req.logger.info("FFmpeg stderr (поток): \(stderrOutput)")
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        process.waitUntilExit()
        req.logger.info("FFmpeg успешно запущен")

        let endTime = Date()
        let durationTime = endTime.timeIntervalSince(startTime)
        req.logger.info("Время завершения FFmpeg: \(endTime), длительность: \(durationTime) секунд")

        req.logger.info("Ожидаем завершения FFmpeg... Завершено.")

        guard FileManager.default.fileExists(atPath: outputPath) else {
            throw Abort(.internalServerError, reason: "FFmpeg не смог обработать видео")
        }

        req.logger.info("Видео успешно обработано и сохранено по пути: \(outputPath)")
        req.logger.info("Видео обработано, путь к обработанному файлу: \(outputPath), длительность: \(duration) секунд")

        // Отправляем обработанное видео как видеокружок
        let sendVideoUrl = URI(string: "https://api.telegram.org/bot\(botToken)/sendVideoNote")
        let boundary = UUID().uuidString
        var requestBody = ByteBufferAllocator().buffer(capacity: 0)

        req.logger.info("Читаем файл перед отправкой...")
        let processedVideoData = try Data(contentsOf: URL(fileURLWithPath: outputPath))
        req.logger.info("Размер обработанного видео: \(processedVideoData.count) байт")

        requestBody.writeString("--\(boundary)\r\n")
        requestBody.writeString("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n")
        requestBody.writeString("\(chatId)\r\n")

        requestBody.writeString("--\(boundary)\r\n")
        requestBody.writeString("Content-Disposition: form-data; name=\"video_note\"; filename=\"video.mp4\"\r\n")
        requestBody.writeString("Content-Type: video/mp4\r\n\r\n")
        requestBody.writeBytes(processedVideoData)
        requestBody.writeString("\r\n")

        requestBody.writeString("--\(boundary)--\r\n")

        req.logger.info("Тело запроса multipart/form-data:\n\(requestBody.getString(at: 0, length: min(requestBody.readableBytes, 1024)) ?? "Пустое тело")")

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "multipart/form-data; boundary=\(boundary)")

        req.logger.info("Отправляем видеокружок в Telegram...")
        let response = try await req.client.post(sendVideoUrl, headers: headers) { post in
            post.body = requestBody
        }.get()

        req.logger.info("Получен ответ от Telegram API. Статус: \(response.status)")
        if let responseBody = response.body {
            let responseData = responseBody.getData(at: 0, length: responseBody.readableBytes) ?? Data()
            req.logger.info("Тело ответа: \(String(data: responseData, encoding: .utf8) ?? "Не удалось декодировать тело ответа")")
        }

        guard response.status == HTTPStatus.ok else {
            throw Abort(.badRequest, reason: "Не удалось отправить видеокружок")
        }

        // Удаляем файлы после успешной отправки
        try FileManager.default.removeItem(atPath: inputPath)
        try FileManager.default.removeItem(atPath: outputPath)
        req.logger.info("Входной файл удалён после успешной отправки: \(inputPath)")
        req.logger.info("Выходной файл удалён после успешной отправки: \(outputPath)")
    }

    func processUploadedVideo(filePath: String, cropData: CropData) async throws {
        let outputPath = filePath.replacingOccurrences(of: ".mp4", with: "_processed.mp4")
        
        // Получаем длительность видео
        let duration = try await getVideoDuration(inputPath: filePath)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss"
        req.logger.info("Длительность видео: \(duration) секунд [\(dateFormatter.string(from: Date()))]")
        
        if duration > 60 {
            throw Abort(.badRequest, reason: "Видео слишком длинное (\(duration) секунд). Максимальная длительность — 60 секунд.")
        }
        
        // Обрабатываем видео с помощью FFmpeg
        req.logger.info("Начинаем обработку видео через ffmpeg... [\(dateFormatter.string(from: Date()))]")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        
        // Получаем размеры исходного видео
        let videoSize = try await getVideoSize(inputPath: filePath)
        
        // Вычисляем размер и координаты для обрезки с учетом масштаба
        let cropSize = min(videoSize.width, videoSize.height)
        let scaledX = Int(Double(videoSize.width) * cropData.x * cropData.scale)
        let scaledY = Int(Double(videoSize.height) * cropData.y * cropData.scale)
        
        // Проверяем и корректируем координаты, чтобы область не выходила за пределы видео
        let safeX = max(0, min(scaledX, videoSize.width - cropSize))
        let safeY = max(0, min(scaledY, videoSize.height - cropSize))
        
        let cropFilter = "crop=\(cropSize):\(cropSize):\(safeX):\(safeY)"
        let seekParam = cropData.currentTime > 0 ? ["-ss", String(cropData.currentTime)] : []
        
        process.arguments = seekParam + [
            "-i", filePath,
            "-vf", "\(cropFilter),scale=640:640,format=yuv420p",
            "-t", "59",
            "-c:v", "libx264",
            "-preset", "fast",
            "-b:v", "2M",
            "-maxrate", "2M",
            "-bufsize", "2M",
            "-c:a", "aac",
            "-b:a", "192k",
            "-ar", "44100",
            "-ac", "2",
            "-movflags", "+faststart",
            "-y", outputPath
        ]
        
        req.logger.info("Запускаем FFmpeg с параметрами кропа: x=\(safeX), y=\(safeY), size=\(cropSize), scale=\(cropData.scale) [\(dateFormatter.string(from: Date()))]")
        
        let stderr = Pipe()
        process.standardError = stderr
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        
        try process.run()
        req.logger.info("Запускаем FFmpeg с параметрами: \(process.arguments?.joined(separator: "") ?? "") [\(dateFormatter.string(from: Date()))]")
        
        // Читаем stderr в реальном времени
        let stderrHandle = stderr.fileHandleForReading
        while process.isRunning {
            let data = stderrHandle.availableData
            if !data.isEmpty, let stderrOutput = String(data: data, encoding: .utf8) {
                req.logger.info("FFmpeg stderr (поток): \(stderrOutput)")
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        
        process.waitUntilExit()
        req.logger.info("FFmpeg успешно завершил работу [\(dateFormatter.string(from: Date()))]")
        
        guard FileManager.default.fileExists(atPath: outputPath) else {
            throw Abort(.internalServerError, reason: "FFmpeg не смог обработать видео")
        }
        
        req.logger.info("Видео успешно обработано [\(dateFormatter.string(from: Date()))]")
    }
    
    private func getVideoSize(inputPath: String) async throws -> (width: Int, height: Int) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
        process.arguments = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=width,height",
            "-of", "csv=p=0",
            inputPath
        ]
        
        let stdout = Pipe()
        process.standardOutput = stdout
        
        try process.run()
        process.waitUntilExit()
        
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: stdoutData, encoding: .utf8) else {
            throw Abort(.internalServerError, reason: "Не удалось получить размеры видео")
        }
        
        let dimensions = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
        guard dimensions.count == 2,
              let width = Int(dimensions[0]),
              let height = Int(dimensions[1]) else {
            throw Abort(.internalServerError, reason: "Неверный формат размеров видео")
        }
        
        return (width: width, height: height)
    }
    
    private func getVideoDuration(inputPath: String) async throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
        process.arguments = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            inputPath
        ]
        
        let stdout = Pipe()
        process.standardOutput = stdout
        
        try process.run()
        process.waitUntilExit()
        
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let durationString = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let duration = Double(durationString) else {
            throw Abort(.internalServerError, reason: "Не удалось определить длительность видео")
        }
        
        return Int(duration)
    }
}