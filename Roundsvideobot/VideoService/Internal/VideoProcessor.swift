import Vapor
import Foundation
import NIO
import AsyncHTTPClient
// import App // если CropData определён в общем модуле, иначе скорректировать импорт

struct VideoProcessor {
    let req: Request

    var botToken: String {
        Environment.get("VIDEO_BOT_TOKEN") ?? ""
    }

    var tempDir: String {
        Environment.get("TEMP_DIR") ?? "Roundsvideobot/Resources/temporaryvideoFiles/"
    }

    func downloadAndProcess(videoId: String, chatId: String) async throws -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let uniqueId = UUID().uuidString.prefix(8)
        let inputFileName = "input_\(timestamp)_\(uniqueId).mp4"
        let outputFileName = "output_\(timestamp)_\(uniqueId).mp4"
        
        let inputUrl = URL(fileURLWithPath: tempDir).appendingPathComponent(inputFileName)
        let outputUrl = URL(fileURLWithPath: tempDir).appendingPathComponent(outputFileName)
        let inputPath = inputUrl.path
        let outputPath = outputUrl.path

        defer {
            // Удаляем временные файлы после обработки
            try? FileManager.default.removeItem(at: inputUrl)
            try? FileManager.default.removeItem(at: outputUrl)
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
        try videoData.write(to: inputUrl)
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

        // Ищем ffmpeg в стандартных местах
        let ffmpegPaths = ["/usr/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg", "ffmpeg"]
        var ffmpegPath: String?
        for path in ffmpegPaths {
            if FileManager.default.fileExists(atPath: path) || path == "ffmpeg" {
                ffmpegPath = path
                break
            }
        }
        guard let ffmpeg = ffmpegPath else {
            throw Abort(.internalServerError, reason: "ffmpeg not found")
        }
        req.logger.info("Using ffmpeg at: \(ffmpeg)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
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
        let processedVideoData = try Data(contentsOf: outputUrl)
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

        return outputUrl
    }

    func processUploadedVideo(filePath: String, cropData: CropData) async throws -> URL {
        let fileUrl = URL(fileURLWithPath: filePath)
        let outputFileName = fileUrl.deletingPathExtension().lastPathComponent + ".processed.mp4"
        let outputUrl = URL(fileURLWithPath: tempDir).appendingPathComponent(outputFileName)
        let outputPath = outputUrl.path

        // Получаем длительность видео
        let duration = try await getVideoDuration(inputPath: filePath)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss"
        req.logger.info("Длительность видео: \(duration) секунд [\(dateFormatter.string(from: Date()))]")

        if duration > 60 {
            throw Abort(.badRequest, reason: "Видео слишком длинное (\(duration) секунд). Максимальная длительность — 60 секунд.")
        }

        // Получаем размеры исходного видео в пикселях
        var videoSize = try await getVideoSize(inputPath: filePath)

        // Учитываем поворот (rotation) при расчёте координат
        let rotation = try await getVideoRotationDegrees(inputPath: filePath)
        req.logger.info("Rotation tag: \(rotation)°")
        if abs(rotation) == 90 {
            videoSize = (width: videoSize.height, height: videoSize.width)
        }

        // Преобразуем нормализованные координаты фронтенда (центр и размер области) в пиксели
        // Фронт передает x,y как центр области в долях от [0,1], width/height — размер области в долях
        let centerX = cropData.x * Double(videoSize.width)
        let centerY = cropData.y * Double(videoSize.height)
        let sizePxDouble = min(cropData.width * Double(videoSize.width), cropData.height * Double(videoSize.height))
        // Немного отдаляем (расширяем область кропа), чтобы уменьшить зум
        let zoomOutFactor = 1.45
        var cropSize = Int(round(sizePxDouble * zoomOutFactor))

        // Вычисляем левый верхний угол области
        var x = Int(round(centerX - Double(cropSize) / 2.0))
        var y = Int(round(centerY - Double(cropSize) / 2.0))
        // Чуть поднимаем область (отрицательное направление Y)
        let verticalBias = Int(round(Double(videoSize.height) * -0.02))
        y += verticalBias

        // Ограничиваем в пределах кадра
        cropSize = max(2, min(cropSize, min(videoSize.width, videoSize.height)))
        x = max(0, min(x, videoSize.width - cropSize))
        y = max(0, min(y, videoSize.height - cropSize))

        // Для совместимости с кодеками приводим к четным значениям
        if cropSize % 2 != 0 { cropSize -= 1 }
        if x % 2 != 0 { x -= 1 }
        if y % 2 != 0 { y -= 1 }

        // Формируем цепочку фильтров: сначала поворот (если требуется), затем кроп и скейл
        var filters: [String] = []
        if rotation == -90 || rotation == 270 {
            filters.append("transpose=1")
        } else if rotation == 90 || rotation == -270 {
            filters.append("transpose=2")
        } else if abs(rotation) == 180 {
            filters.append("transpose=2,transpose=2")
        }
        let cropFilter = "crop=\(cropSize):\(cropSize):\(x):\(y)"
        filters.append(cropFilter)
        filters.append("scale=640:640,format=yuv420p")
        let filterChain = filters.joined(separator: ",")

        // Обрабатываем видео с помощью FFmpeg
        req.logger.info("Запускаем FFmpeg с параметрами кропа: x=\(x), y=\(y), size=\(cropSize) [\(dateFormatter.string(from: Date()))]")
        
        // Ищем ffmpeg в стандартных местах
        let ffmpegPaths = ["/usr/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg", "ffmpeg"]
        var ffmpegPath: String?
        for path in ffmpegPaths {
            if FileManager.default.fileExists(atPath: path) || path == "ffmpeg" {
                ffmpegPath = path
                break
            }
        }
        guard let ffmpeg = ffmpegPath else {
            throw Abort(.internalServerError, reason: "ffmpeg not found")
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-i", filePath,
            "-vf", filterChain,
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
        
        let stderr = Pipe()
        process.standardError = stderr
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        
        try process.run()
        req.logger.info("Запускаем FFmpeg с параметрами: \(process.arguments?.joined(separator: " ") ?? "") [\(dateFormatter.string(from: Date()))]")
        
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
        return outputUrl
    }
    
    private func getVideoSize(inputPath: String) async throws -> (width: Int, height: Int) {
        // Ищем ffprobe в стандартных местах
        let ffprobePaths = ["/usr/bin/ffprobe", "/usr/local/bin/ffprobe", "/opt/homebrew/bin/ffprobe", "ffprobe"]
        var ffprobePath: String?
        for path in ffprobePaths {
            if FileManager.default.fileExists(atPath: path) || path == "ffprobe" {
                ffprobePath = path
                break
            }
        }
        guard let probePath = ffprobePath else {
            throw Abort(.internalServerError, reason: "ffprobe не найден")
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: probePath)
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
        // Ищем ffprobe в стандартных местах
        let ffprobePaths = ["/usr/bin/ffprobe", "/usr/local/bin/ffprobe", "/opt/homebrew/bin/ffprobe", "ffprobe"]
        var ffprobePath: String?
        for path in ffprobePaths {
            if FileManager.default.fileExists(atPath: path) || path == "ffprobe" {
                ffprobePath = path
                break
            }
        }
        guard let probePath = ffprobePath else {
            throw Abort(.internalServerError, reason: "ffprobe не найден")
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: probePath)
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
            throw Vapor.Abort(.internalServerError, reason: "Не удалось определить длительность видео")
        }
        
        return Int(duration)
    }

    // Определяем угол поворота видео из метаданных (если есть)
    private func getVideoRotationDegrees(inputPath: String) async throws -> Int {
        // Ищем ffprobe в стандартных местах
        let ffprobePaths = ["/usr/bin/ffprobe", "/usr/local/bin/ffprobe", "/opt/homebrew/bin/ffprobe", "ffprobe"]
        var ffprobePath: String?
        for path in ffprobePaths {
            if FileManager.default.fileExists(atPath: path) || path == "ffprobe" {
                ffprobePath = path
                break
            }
        }
        guard let probePath = ffprobePath else {
            throw Abort(.internalServerError, reason: "ffprobe не найден")
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: probePath)
        process.arguments = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream_tags=rotate",
            "-of", "default=noprint_wrappers=1:nokey=1",
            inputPath
        ]

        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        process.waitUntilExit()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return 0
        }
        if let deg = Int(text) {
            var d = deg % 360
            if d > 180 { d -= 360 }
            if d <= -180 { d += 360 }
            return d
        }
        return 0
    }

    // Функция для отправки текстового сообщения в чат
    private func sendMessage(_ text: String, to chatId: String) async throws {
        let sendMessageUrl = URI(string: "https://api.telegram.org/bot\(botToken)/sendMessage")
        let boundary = UUID().uuidString
        var body = ByteBufferAllocator().buffer(capacity: 0)
        
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n")
        body.writeString("\(chatId)\r\n")
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"text\"\r\n\r\n")
        body.writeString("\(text)\r\n")
        body.writeString("--\(boundary)--\r\n")
        
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "multipart/form-data; boundary=\(boundary)")
        
        let response = try await req.client.post(sendMessageUrl, headers: headers) { post in
            post.body = body
        }.get()
        
        req.logger.info("Сообщение отправлено в чат \(chatId): \(text), статус: \(response.status)")
    }

    // Общая функция для обработки видео и отправки кружочка
    func processAndSendCircleVideo(inputPath: String, chatId: String) async throws {
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let uniqueId = UUID().uuidString.prefix(8)
        let outputFileName = "output_\(timestamp)_\(uniqueId).mp4"
        let outputUrl = URL(fileURLWithPath: tempDir).appendingPathComponent(outputFileName)
        let outputPath = outputUrl.path

        defer {
            // Удаляем временные файлы после обработки
            try? FileManager.default.removeItem(at: outputUrl)
            req.logger.info("Выходной файл удалён после обработки: \(outputPath)")
        }

        // Проверяем длительность видео
        let duration = try await getVideoDuration(inputPath: inputPath)
        req.logger.info("Длительность видео: \(duration) секунд")

        if duration > 60 {
            throw Abort(.badRequest, reason: "Видео слишком длинное (\(duration) секунд). Максимальная длительность — 60 секунд.")
        }

        // Рассчитываем центрированный квадратный кроп с учётом поворота
        var videoSize = try await getVideoSize(inputPath: inputPath)
        let rotation = try await getVideoRotationDegrees(inputPath: inputPath)
        req.logger.info("Rotation tag (direct bot): \(rotation)°")
        if abs(rotation) == 90 {
            videoSize = (width: videoSize.height, height: videoSize.width)
        }

        var cropSize = min(videoSize.width, videoSize.height)
        var x = (videoSize.width - cropSize) / 2
        var y = (videoSize.height - cropSize) / 2
        // Приводим к чётным значениям
        if cropSize % 2 != 0 { cropSize -= 1 }
        if x % 2 != 0 { x -= 1 }
        if y % 2 != 0 { y -= 1 }

        // Цепочка фильтров: нормализуем ориентацию -> центр. кроп -> scale
        var filters: [String] = []
        if rotation == -90 || rotation == 270 {
            filters.append("transpose=1")
        } else if rotation == 90 || rotation == -270 {
            filters.append("transpose=2")
        } else if abs(rotation) == 180 {
            filters.append("transpose=2,transpose=2")
        }
        filters.append("crop=\(cropSize):\(cropSize):\(x):\(y)")
        filters.append("scale=640:640,format=yuv420p")
        let filterChain = filters.joined(separator: ",")

        // Обрабатываем видео с помощью FFmpeg
        req.logger.info("Начинаем обработку видео через ffmpeg (direct bot)...")
        
        // Ищем ffmpeg в стандартных местах
        let ffmpegPaths = ["/usr/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg", "ffmpeg"]
        var ffmpegPath: String?
        for path in ffmpegPaths {
            if FileManager.default.fileExists(atPath: path) || path == "ffmpeg" {
                ffmpegPath = path
                break
            }
        }
        guard let ffmpeg = ffmpegPath else {
            throw Abort(.internalServerError, reason: "ffmpeg not found")
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-i", inputPath,
            "-vf", filterChain,
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
        req.logger.info("FFmpeg успешно завершил работу")

        guard FileManager.default.fileExists(atPath: outputPath) else {
            throw Abort(.internalServerError, reason: "FFmpeg не смог обработать видео")
        }

        req.logger.info("Видео успешно обработано и сохранено по пути: \(outputPath)")

        // Отправляем сообщение "Готово!" перед отправкой кружка
        try await sendMessage("✅ Готово!", to: chatId)

        // Отправляем обработанное видео как видеокружок
        let sendVideoUrl = URI(string: "https://api.telegram.org/bot\(botToken)/sendVideoNote")
        let boundary = UUID().uuidString
        var requestBody = ByteBufferAllocator().buffer(capacity: 0)

        req.logger.info("Читаем файл перед отправкой...")
        let processedVideoData = try Data(contentsOf: outputUrl)
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
    }
}