import Vapor
import Foundation
import NIO
import AsyncHTTPClient
// import App // если CropData определён в общем модуле, иначе скорректировать импорт

struct VideoProcessor {
    private let request: Request?
    private let app: Application?

    init(req: Request) {
        self.request = req
        self.app = nil
    }

    init(app: Application) {
        self.request = nil
        self.app = app
    }

    private var logger: Logger {
        request?.logger ?? app!.logger
    }

    private var client: Client {
        request?.client ?? app!.client
    }

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
            logger.info("Входной файл удалён после обработки: \(inputPath)")
            logger.info("Выходной файл удалён после обработки: \(outputPath)")
        }

        // Получаем информацию о файле
        let getFileUrl = URI(string: "https://api.telegram.org/bot\(botToken)/getFile?file_id=\(videoId)")
        logger.info("Запрашиваем информацию о файле по URL: \(getFileUrl)")

        let fileResponse = try await client.get(getFileUrl).flatMapThrowing { res -> TelegramFileResponse in
            logger.info("Получен ответ от getFile API. Статус: \(res.status)")
            guard res.status == HTTPStatus.ok, let body = res.body else {
                throw Abort(.badRequest, reason: "Не удалось получить информацию о файле")
            }
            let data = body.getData(at: 0, length: body.readableBytes) ?? Data()
            logger.info("Размер данных ответа getFile: \(data.count) байт")
            let response = try JSONDecoder().decode(TelegramFileResponse.self, from: data)
            logger.info("Успешно декодирован ответ: \(response)")
            return response
        }.get()

        logger.info("Декодирован ответ от Telegram API: \(fileResponse)")

        let filePath = fileResponse.result.file_path
        let downloadUrl = URI(string: "https://api.telegram.org/file/bot\(botToken)/\(filePath)")
        logger.info("URL для скачивания видео: \(downloadUrl)")

        // Скачиваем видео
        logger.info("Начинаем скачивание видео...")
        logger.info("Путь для входного файла: \(inputPath)")
        logger.info("Путь для выходного файла: \(outputPath)")

        logger.info("Скачиваем видео по URL: \(downloadUrl)")
        let downloadResponse = try await client.get(downloadUrl).get()
        guard downloadResponse.status == HTTPStatus.ok, let body = downloadResponse.body else {
            throw Abort(.badRequest, reason: "Не удалось скачать видео")
        }

        let videoData = body.getData(at: 0, length: body.readableBytes) ?? Data()
        try videoData.write(to: inputUrl)
        logger.info("Видео успешно скачано по пути: \(inputPath)")
        logger.info("Размер видео: \(videoData.count) байт")

        // Проверяем размер файла
        let fileSize = videoData.count
        if fileSize > 100 * 1024 * 1024 { // 100 МБ
            throw Abort(.badRequest, reason: "Файл слишком большой (\(fileSize) байт). Максимальный размер — 100 МБ.")
        }

        // Проверяем длительность видео
        let duration = try await getVideoDuration(inputPath: inputPath)
        logger.info("Длительность видео: \(duration) секунд")

        // Обрабатываем видео с помощью FFmpeg
        logger.info("Начинаем обработку видео через ffmpeg...")
        let ffmpegCommand = "ffmpeg -i \(inputPath) -vf scale=640:640,format=yuv420p -t 59 -b:v 512k -r 30 -preset veryfast -movflags +faststart -y \(outputPath)"
        logger.info("Команда ffmpeg: \(ffmpegCommand)")

        let startTime = Date()
        logger.info("Время начала FFmpeg: \(startTime)")

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
        logger.info("Using ffmpeg at: \(ffmpeg)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-i", inputPath,
            "-vf", "scale=640:640,format=yuv420p",
            "-t", "59",
            "-b:v", "512k",
            "-r", "30",
            "-preset", "veryfast",
            "-movflags", "+faststart",
            "-y", outputPath
        ]

        let stderr = Pipe()
        process.standardError = stderr
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")

        try process.run()
        logger.info("Запускаем FFmpeg...")

        // Читаем stderr в реальном времени
        let stderrHandle = stderr.fileHandleForReading
        while process.isRunning {
            let data = stderrHandle.availableData
            if !data.isEmpty, let stderrOutput = String(data: data, encoding: .utf8) {
                logger.info("FFmpeg stderr (поток): \(stderrOutput)")
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        process.waitUntilExit()
        logger.info("FFmpeg успешно запущен")

        let endTime = Date()
        let durationTime = endTime.timeIntervalSince(startTime)
        logger.info("Время завершения FFmpeg: \(endTime), длительность: \(durationTime) секунд")

        logger.info("Ожидаем завершения FFmpeg... Завершено.")

        guard FileManager.default.fileExists(atPath: outputPath) else {
            throw Abort(.internalServerError, reason: "FFmpeg не смог обработать видео")
        }

        logger.info("Видео успешно обработано и сохранено по пути: \(outputPath)")
        logger.info("Видео обработано, путь к обработанному файлу: \(outputPath), длительность: \(duration) секунд")

        // Отправляем обработанное видео как видеокружок
        let sendVideoUrl = URI(string: "https://api.telegram.org/bot\(botToken)/sendVideoNote")
        let boundary = UUID().uuidString
        var requestBody = ByteBufferAllocator().buffer(capacity: 0)

        logger.info("Читаем файл перед отправкой...")
        let processedVideoData = try Data(contentsOf: outputUrl)
        logger.info("Размер обработанного видео: \(processedVideoData.count) байт")

        requestBody.writeString("--\(boundary)\r\n")
        requestBody.writeString("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n")
        requestBody.writeString("\(chatId)\r\n")

        requestBody.writeString("--\(boundary)\r\n")
        requestBody.writeString("Content-Disposition: form-data; name=\"video_note\"; filename=\"video.mp4\"\r\n")
        requestBody.writeString("Content-Type: video/mp4\r\n\r\n")
        requestBody.writeBytes(processedVideoData)
        requestBody.writeString("\r\n")

        requestBody.writeString("--\(boundary)--\r\n")

        logger.info("Тело запроса multipart/form-data:\n\(requestBody.getString(at: 0, length: min(requestBody.readableBytes, 1024)) ?? "Пустое тело")")

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "multipart/form-data; boundary=\(boundary)")

        logger.info("Отправляем видеокружок в Telegram...")
        let response = try await client.post(sendVideoUrl, headers: headers) { post in
            post.body = requestBody
        }.get()

        logger.info("Получен ответ от Telegram API. Статус: \(response.status)")
        if let responseBody = response.body {
            let responseData = responseBody.getData(at: 0, length: responseBody.readableBytes) ?? Data()
            logger.info("Тело ответа: \(String(data: responseData, encoding: .utf8) ?? "Не удалось декодировать тело ответа")")
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

        // Получаем все метаданные одним вызовом ffprobe (быстрее для больших файлов)
        let (duration, storageSize, rotation) = try await getVideoMetadata(inputPath: filePath)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss"
        logger.info("Длительность видео: \(duration) секунд [\(dateFormatter.string(from: Date()))]")

        if duration > 60 {
            throw Abort(.badRequest, reason: "Видео слишком длинное (\(duration) секунд). Максимальная длительность — 60 секунд.")
        }

        logger.info("Rotation tag: \(rotation)°")

        // Display — как видит пользователь (frontend naturalWidth×naturalHeight).
        // При ±90°: display = (height×width), иначе = storage.
        let displayWidth: Int
        let displayHeight: Int
        if abs(rotation) == 90 {
            displayWidth = storageSize.height
            displayHeight = storageSize.width
        } else {
            displayWidth = storageSize.width
            displayHeight = storageSize.height
        }
        logger.info("Display размеры: \(displayWidth)×\(displayHeight) (storage: \(storageSize.width)×\(storageSize.height))")

        // Фронт: x,y — центр кропа в [0,1], (0,0)=левый верх, Y вниз.
        // cropOffsetY: смещение по Y (px). Отрицательное = голова выше в кружке.
        let cropOffsetY: Double = 130
        let centerX = cropData.x * Double(displayWidth)
        let centerY = cropData.y * Double(displayHeight) + cropOffsetY
        let minSide = Double(min(displayWidth, displayHeight))
        let sizePxDouble = min(
            cropData.width * minSide,
            cropData.height * minSide,
            minSide
        )
        var cropSize = Int(round(sizePxDouble))
        cropSize = max(2, min(cropSize, min(displayWidth, displayHeight)))
        if cropSize % 2 != 0 { cropSize -= 1 }
        let half = Double(cropSize) / 2.0
        let minCX = half
        let maxCX = Double(displayWidth) - half
        let minCY = half
        let maxCY = Double(displayHeight) - half
        let clampedCX = max(minCX, min(maxCX, centerX))
        let clampedCY = max(minCY, min(maxCY, centerY))
        var x = Int(round(clampedCX - half))
        var y = Int(round(clampedCY - half))
        x = max(0, min(x, displayWidth - cropSize))
        y = max(0, min(y, displayHeight - cropSize))

        logger.info("Кроп: offsetY=\(cropOffsetY), center=(\(centerX), \(centerY))→(\(clampedCX), \(clampedCY)), size=\(cropSize), x=\(x), y=\(y)")

        if x % 2 != 0 { x -= 1 }
        if y % 2 != 0 { y -= 1 }

        // Формируем цепочку фильтров: сначала поворот (если требуется), затем кроп и скейл
        // ВАЖНО: transpose применяем ТОЛЬКО если поворот действительно определен
        var filters: [String] = []
        if rotation == -90 || rotation == 270 {
            // -90°: 90° CCW + vflip (transpose=0), иначе получается «вниз головой»
            filters.append("transpose=0")
            logger.info("Применяем transpose=0 для поворота -90°")
        } else if rotation == 90 || rotation == -270 {
            // +90°: 90° CW + vflip (transpose=3)
            filters.append("transpose=3")
            logger.info("Применяем transpose=3 для поворота +90°")
        } else if abs(rotation) == 180 {
            filters.append("transpose=2,transpose=2")
            logger.info("Применяем transpose=2,transpose=2 для поворота 180°")
        } else {
            logger.info("Поворот не применяется (rotation=\(rotation)°)")
        }
        let cropFilter = "crop=\(cropSize):\(cropSize):\(x):\(y)"
        filters.append(cropFilter)
        filters.append("scale=640:640,format=yuv420p")
        let filterChain = filters.joined(separator: ",")
        logger.info("Цепочка фильтров FFmpeg: \(filterChain)")

        // Обрабатываем видео с помощью FFmpeg
        logger.info("Запускаем FFmpeg с параметрами кропа: x=\(x), y=\(y), size=\(cropSize) [\(dateFormatter.string(from: Date()))]")
        
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
            "-noautorotate",
            "-i", filePath,
            "-vf", filterChain,
            "-t", "59",
            "-b:v", "512k",
            "-r", "30",
            "-preset", "veryfast",
            "-movflags", "+faststart",
            "-metadata:s:v:0", "rotate=0",
            "-y", outputPath
        ]
        
        let stderr = Pipe()
        process.standardError = stderr
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        
        try process.run()
        logger.info("Запускаем FFmpeg с параметрами: \(process.arguments?.joined(separator: " ") ?? "") [\(dateFormatter.string(from: Date()))]")
        
        var stderrChunks: [Data] = []
        let stderrHandle = stderr.fileHandleForReading
        while process.isRunning {
            let data = stderrHandle.availableData
            if !data.isEmpty {
                stderrChunks.append(data)
                if let s = String(data: data, encoding: .utf8) { logger.info("FFmpeg stderr (поток): \(s)") }
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        let stderrTail = stderrHandle.readDataToEndOfFile()
        if !stderrTail.isEmpty { stderrChunks.append(stderrTail) }
        
        process.waitUntilExit()
        let exitCode = process.terminationStatus
        let stderrFull = stderrChunks.reduce(Data(), +)
        let stderrStr = String(data: stderrFull, encoding: .utf8) ?? ""
        
        guard exitCode == 0 else {
            logger.error("FFmpeg upload завершился с кодом \(exitCode). Stderr: \(stderrStr)")
            throw Abort(.internalServerError, reason: "FFmpeg не смог обработать видео (код \(exitCode))")
        }
        guard FileManager.default.fileExists(atPath: outputPath) else {
            logger.error("FFmpeg upload: выходной файл отсутствует. Stderr: \(stderrStr)")
            throw Abort(.internalServerError, reason: "FFmpeg не создал выходной файл")
        }
        
        logger.info("FFmpeg успешно завершил работу (upload) [\(dateFormatter.string(from: Date()))]")
        return outputUrl
    }

    /// Обработка загрузки из мини-апп: process → sendVideoNote → cleanup. Для фоновой задачи (app-based).
    func processUploadedVideoAndSend(filePath inputPath: String, cropData: CropData, chatId: String) async throws {
        let inputUrl = URL(fileURLWithPath: inputPath)
        defer { try? FileManager.default.removeItem(at: inputUrl) }
        let processedUrl = try await processUploadedVideo(filePath: inputPath, cropData: cropData)
        defer { try? FileManager.default.removeItem(at: processedUrl) }
        let sendVideoUrl = URI(string: "https://api.telegram.org/bot\(botToken)/sendVideoNote")
        let boundary = UUID().uuidString
        var body = ByteBufferAllocator().buffer(capacity: 0)
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n")
        body.writeString("\(chatId)\r\n")
        let processedData = try Data(contentsOf: processedUrl)
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"video_note\"; filename=\"video.mp4\"\r\n")
        body.writeString("Content-Type: video/mp4\r\n\r\n")
        body.writeBytes(processedData)
        body.writeString("\r\n")
        body.writeString("--\(boundary)--\r\n")
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "multipart/form-data; boundary=\(boundary)")
        let response = try await client.post(sendVideoUrl, headers: headers) { post in
            post.body = body
        }.get()
        guard response.status == .ok else {
            let bodyStr: String
            if let rb = response.body, let d = rb.getData(at: 0, length: rb.readableBytes), let s = String(data: d, encoding: .utf8) {
                bodyStr = s
            } else {
                bodyStr = ""
            }
            if bodyStr.contains("VOICE_MESSAGES_FORBIDDEN") {
                try? await sendVoiceMessagesForbiddenHint(to: chatId)
                throw Abort(.badRequest, reason: "VOICE_MESSAGES_FORBIDDEN")
            }
            if !bodyStr.isEmpty {
                throw Abort(.badRequest, reason: "Ошибка при отправке видео: \(bodyStr)")
            }
            throw Abort(.badRequest, reason: "Не удалось отправить видеокружок")
        }
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
        
        // Сначала проверяем тег rotate
        let process1 = Process()
        process1.executableURL = URL(fileURLWithPath: probePath)
        process1.arguments = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream_tags=rotate",
            "-of", "default=noprint_wrappers=1:nokey=1",
            inputPath
        ]

        let stdout1 = Pipe()
        process1.standardOutput = stdout1
        try process1.run()
        process1.waitUntilExit()

        let stdoutData1 = stdout1.fileHandleForReading.readDataToEndOfFile()
        if let text = String(data: stdoutData1, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
        if let deg = Int(text) {
            var d = deg % 360
            if d > 180 { d -= 360 }
            if d <= -180 { d += 360 }
            return d
        }
        }
        
        // Если тег rotate не найден, проверяем displaymatrix через ffprobe с выводом в JSON
        let process2 = Process()
        process2.executableURL = URL(fileURLWithPath: probePath)
        process2.arguments = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=side_data_list",
            "-of", "json",
            inputPath
        ]

        let stdout2 = Pipe()
        process2.standardOutput = stdout2
        try process2.run()
        process2.waitUntilExit()

        let stdoutData2 = stdout2.fileHandleForReading.readDataToEndOfFile()
        if let jsonText = String(data: stdoutData2, encoding: .utf8),
           let jsonData = jsonText.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let streams = json["streams"] as? [[String: Any]],
           let stream = streams.first,
           let sideDataList = stream["side_data_list"] as? [[String: Any]] {
            for sideData in sideDataList {
                if let rotation = sideData["rotation"] as? Double {
                    var d = Int(round(rotation)) % 360
                    if d > 180 { d -= 360 }
                    if d <= -180 { d += 360 }
                    return d
                }
            }
        }
        
        // Если JSON не помог, пробуем парсить вывод ffprobe с -show_streams
        let process3 = Process()
        process3.executableURL = URL(fileURLWithPath: probePath)
        process3.arguments = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_streams",
            inputPath
        ]

        let stdout3 = Pipe()
        let stderr3 = Pipe()
        process3.standardOutput = stdout3
        process3.standardError = stderr3
        try process3.run()
        process3.waitUntilExit()

        // Проверяем и stdout, и stderr
        let stdoutData3 = stdout3.fileHandleForReading.readDataToEndOfFile()
        let stderrData3 = stderr3.fileHandleForReading.readDataToEndOfFile()
        
        let stdoutText = String(data: stdoutData3, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData3, encoding: .utf8) ?? ""
        let allOutput = stdoutText + stderrText
        
        if !allOutput.isEmpty {
            // Ищем строку вида "displaymatrix: rotation of -90.00 degrees" или "rotation of -90.00"
            let lines = allOutput.components(separatedBy: CharacterSet.newlines)
            for line in lines {
                // Парсим строку вида "rotation of -90.00 degrees" или "rotation=-90"
                // Ищем паттерн "rotation of -90.00" или "rotation of -90"
                if line.contains("rotation") {
                    // Пробуем разные паттерны
                    let patterns = [
                        #"rotation\s+of\s+(-?\d+\.?\d*)"#,
                        #"rotation\s*=\s*(-?\d+\.?\d*)"#,
                        #"rotation:\s*(-?\d+\.?\d*)"#
                    ]
                    
                    for pattern in patterns {
                        if let rotationMatch = line.range(of: pattern, options: .regularExpression) {
                            let matchedStr = String(line[rotationMatch])
                            // Извлекаем число из строки вида "rotation of -90.00" -> "-90.00"
                            if let numMatch = matchedStr.range(of: #"-?\d+\.?\d*"#, options: .regularExpression) {
                                let degStr = String(matchedStr[numMatch])
                                if let deg = Double(degStr) {
                                    var d = Int(round(deg)) % 360
                                    if d > 180 { d -= 360 }
                                    if d <= -180 { d += 360 }
                                    logger.info("Найден поворот из ffprobe: \(d)° (строка: \(line))")
                                    return d
                                }
                            }
                        }
                    }
                }
            }
        }
        
        logger.info("Поворот не найден в выводе ffprobe, возвращаем 0°")
        return 0
    }

    /// Получает все метаданные видео одним вызовом ffprobe (быстрее для больших файлов)
    private func getVideoMetadata(inputPath: String) async throws -> (duration: Int, size: (width: Int, height: Int), rotation: Int) {
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
            "-show_entries", "stream=width,height,duration:stream_tags=rotate:stream_side_data=rotation",
            "-of", "json",
            inputPath
        ]
        
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        process.waitUntilExit()
        
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let jsonText = String(data: stdoutData, encoding: .utf8),
              let jsonData = jsonText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]],
              let stream = streams.first else {
            throw Abort(.internalServerError, reason: "Не удалось получить метаданные видео")
        }
        
        // Duration
        var duration: Int = 0
        if let dur = stream["duration"] as? String, let d = Double(dur) {
            duration = Int(round(d))
        } else if let dur = stream["duration"] as? Double {
            duration = Int(round(dur))
        }
        
        // Size
        guard let width = stream["width"] as? Int, let height = stream["height"] as? Int else {
            throw Abort(.internalServerError, reason: "Не удалось получить размеры видео")
        }
        
        // Rotation: сначала из tags, потом из side_data
        var rotation: Int = 0
        if let tags = stream["tags"] as? [String: Any], let rotStr = tags["rotate"] as? String, let rot = Int(rotStr) {
            var d = rot % 360
            if d > 180 { d -= 360 }
            if d <= -180 { d += 360 }
            rotation = d
        } else if let sideDataList = stream["side_data_list"] as? [[String: Any]] {
            for sideData in sideDataList {
                if let rot = sideData["rotation"] as? Double {
                    var d = Int(round(rot)) % 360
                    if d > 180 { d -= 360 }
                    if d <= -180 { d += 360 }
                    rotation = d
                    break
                }
            }
        }
        
        return (duration: duration, size: (width: width, height: height), rotation: rotation)
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
        
        let response = try await client.post(sendMessageUrl, headers: headers) { post in
            post.body = body
        }.get()
        
        logger.info("Сообщение отправлено в чат \(chatId): \(text), статус: \(response.status)")
    }

    /// Отправляет пользователю подсказку включить голосовые/видео в конфиденциальности при VOICE_MESSAGES_FORBIDDEN.
    func sendVoiceMessagesForbiddenHint(to chatId: String) async throws {
        let text = "Не удалось отправить видеокружок: у вас отключён приём голосовых и видеосообщений. Включите его в настройках Telegram: Конфиденциальность → Голосовые и видеосообщения."
        try await sendMessage(text, to: chatId)
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
            logger.info("Выходной файл удалён после обработки: \(outputPath)")
        }

        // Проверяем длительность видео
        let duration = try await getVideoDuration(inputPath: inputPath)
        logger.info("Длительность видео: \(duration) секунд")

        if duration > 60 {
            throw Abort(.badRequest, reason: "Видео слишком длинное (\(duration) секунд). Максимальная длительность — 60 секунд.")
        }

        // Рассчитываем центрированный квадратный кроп с учётом поворота
        var videoSize = try await getVideoSize(inputPath: inputPath)
        let rotation = try await getVideoRotationDegrees(inputPath: inputPath)
        logger.info("Rotation tag (direct bot): \(rotation)°")
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
        // -90° → transpose=0 (CCW+vflip); +90° → transpose=3 (CW+vflip)
        var filters: [String] = []
        if rotation == -90 || rotation == 270 {
            filters.append("transpose=0")
        } else if rotation == 90 || rotation == -270 {
            filters.append("transpose=3")
        } else if abs(rotation) == 180 {
            filters.append("transpose=2,transpose=2")
        }
        filters.append("crop=\(cropSize):\(cropSize):\(x):\(y)")
        filters.append("scale=640:640,format=yuv420p")
        let filterChain = filters.joined(separator: ",")

        // Обрабатываем видео с помощью FFmpeg
        logger.info("Начинаем обработку видео через ffmpeg (direct bot)...")
        
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
            "-noautorotate",
            "-i", inputPath,
            "-vf", filterChain,
            "-t", "59",
            "-b:v", "512k",
            "-r", "30",
            "-preset", "veryfast",
            "-movflags", "+faststart",
            "-metadata:s:v:0", "rotate=0",
            "-y", outputPath
        ]

        let stderr = Pipe()
        process.standardError = stderr
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")

        try process.run()
        logger.info("Запускаем FFmpeg (direct bot)...")

        var stderrChunks: [Data] = []
        let stderrHandle = stderr.fileHandleForReading
        while process.isRunning {
            let data = stderrHandle.availableData
            if !data.isEmpty {
                stderrChunks.append(data)
                if let s = String(data: data, encoding: .utf8) { logger.info("FFmpeg stderr (поток): \(s)") }
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        let stderrTail = stderrHandle.readDataToEndOfFile()
        if !stderrTail.isEmpty { stderrChunks.append(stderrTail) }

        process.waitUntilExit()
        let exitCode = process.terminationStatus
        let stderrFull = stderrChunks.reduce(Data(), +)
        let stderrStr = String(data: stderrFull, encoding: .utf8) ?? ""

        guard exitCode == 0 else {
            logger.error("FFmpeg direct bot завершился с кодом \(exitCode). Stderr: \(stderrStr)")
            throw Abort(.internalServerError, reason: "FFmpeg не смог обработать видео (код \(exitCode))")
        }
        guard FileManager.default.fileExists(atPath: outputPath) else {
            logger.error("FFmpeg direct bot: выходной файл отсутствует. Stderr: \(stderrStr)")
            throw Abort(.internalServerError, reason: "FFmpeg не создал выходной файл")
        }

        logger.info("FFmpeg успешно завершил работу (direct bot)")

        logger.info("Видео успешно обработано и сохранено по пути: \(outputPath)")

        // Отправляем сообщение "Готово!" перед отправкой кружка
        try await sendMessage("✅ Готово!", to: chatId)

        // Отправляем обработанное видео как видеокружок
        let sendVideoUrl = URI(string: "https://api.telegram.org/bot\(botToken)/sendVideoNote")
        let boundary = UUID().uuidString
        var requestBody = ByteBufferAllocator().buffer(capacity: 0)

        logger.info("Читаем файл перед отправкой...")
        let processedVideoData = try Data(contentsOf: outputUrl)
        logger.info("Размер обработанного видео: \(processedVideoData.count) байт")

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

        logger.info("Отправляем видеокружок в Telegram...")
        let response = try await client.post(sendVideoUrl, headers: headers) { post in
            post.body = requestBody
        }.get()

        logger.info("Получен ответ от Telegram API. Статус: \(response.status)")
        let bodyStr: String
        if let responseBody = response.body {
            let responseData = responseBody.getData(at: 0, length: responseBody.readableBytes) ?? Data()
            bodyStr = String(data: responseData, encoding: .utf8) ?? ""
            logger.info("Тело ответа: \(bodyStr)")
        } else {
            bodyStr = ""
        }

        guard response.status == HTTPStatus.ok else {
            if bodyStr.contains("VOICE_MESSAGES_FORBIDDEN") {
                try? await sendVoiceMessagesForbiddenHint(to: chatId)
                throw Abort(.badRequest, reason: "VOICE_MESSAGES_FORBIDDEN")
            }
            throw Abort(.badRequest, reason: "Не удалось отправить видеокружок")
        }
    }
}