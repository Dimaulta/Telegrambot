import Vapor
import Foundation

public struct VideoProcessor {
    // Очередь для синхронизации доступа к _isProcessing
    private static let syncQueue = DispatchQueue(label: "com.videoprocessor.sync")
    // Глобальная переменная для ограничения одновременной обработки
    private static nonisolated(unsafe) var _isProcessing = false

    // Безопасный доступ к _isProcessing
    private static var isProcessing: Bool {
        get {
            syncQueue.sync { _isProcessing }
        }
        set {
            syncQueue.sync { _isProcessing = newValue }
        }
    }
    
    public init() {}
    
    public static func downloadAndProcess(fileId: String, chatId: String, req: Request) -> EventLoopFuture<Response> {
        // Проверяем, не обрабатывается ли уже видео
        req.logger.info("Проверка isProcessing: \(isProcessing)")
        guard !isProcessing else {
            req.logger.warning("Другое видео уже обрабатывается, запрос отклонён")
            return req.eventLoop.makeFailedFuture(Abort(.tooManyRequests, reason: "Другое видео уже обрабатывается, попробуйте позже"))
        }
        
        // Устанавливаем флаг обработки
        isProcessing = true
        req.logger.info("Установлен isProcessing = true")
        
        let botToken = "7901916114:AAEAXDcoWhYqq5Wx4TAw1RUaxWxGaXWgf-k"
        let getFileUrl = "https://api.telegram.org/bot\(botToken)/getFile?file_id=\(fileId)"
        
        req.logger.info("Начинаем процесс обработки видео. FileId: \(fileId), ChatId: \(chatId)")
        req.logger.info("Запрашиваем информацию о файле по URL: \(getFileUrl)")

        return req.client.get(URI(string: getFileUrl)).flatMap { res -> EventLoopFuture<TelegramFileResponse> in
            req.logger.info("Получен ответ от getFile API. Статус: \(res.status)")
            guard res.status == HTTPStatus.ok, let body = res.body else {
                req.logger.error("Ошибка в getFile: \(res.status)")
                return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Не удалось получить файл"))
            }
            do {
                let data = body.getData(at: 0, length: body.readableBytes) ?? Data()
                req.logger.info("Размер данных ответа getFile: \(data.count) байт")
                let fileResponse = try JSONDecoder().decode(TelegramFileResponse.self, from: data)
                req.logger.info("Успешно декодирован ответ: \(fileResponse)")
                return req.eventLoop.makeSucceededFuture(fileResponse)
            } catch {
                req.logger.error("Ошибка декодирования getFile: \(error)")
                return req.eventLoop.makeFailedFuture(error)
            }
        }.flatMap { (fileResponse: TelegramFileResponse) -> EventLoopFuture<(String, Int)> in
            req.logger.info("Декодирован ответ от Telegram API: \(fileResponse)")
            let filePath = fileResponse.result.file_path
            let downloadUrl = "https://api.telegram.org/file/bot\(botToken)/\(filePath)"
            req.logger.info("URL для скачивания видео: \(downloadUrl)")

            return processVideo(downloadUrl: downloadUrl, req: req).map { processedFilePath in
                let duration = getVideoDuration(processedFilePath)
                req.logger.info("Видео обработано, путь к обработанному файлу: \(processedFilePath), длительность: \(duration) секунд")
                return (processedFilePath, duration)
            }
        }.flatMap { (processedFilePath, duration) in
            return sendProcessedVideo(processedFilePath, chatId: chatId, req: req)
        }.flatMap { response in
            // Проверяем статус ответа от Telegram
            if response.status == HTTPStatus.ok {
                req.logger.info("Обработка завершена успешно, сбрасываем isProcessing")
                isProcessing = false
                req.logger.info("Видео успешно обработано и отправлено")
                return req.eventLoop.makeSucceededFuture(response)
            } else {
                req.logger.error("Отправка видео в Telegram не удалась, статус: \(response.status)")
                isProcessing = false
                return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Не удалось отправить видео в Telegram: \(response.status)"))
            }
        }.flatMapError { error in
            // Сбрасываем флаг в случае ошибки
            req.logger.info("Обработка завершилась с ошибкой, сбрасываем isProcessing")
            isProcessing = false
            req.logger.error("Ошибка в процессе downloadAndProcess: \(error)")
            return req.eventLoop.makeFailedFuture(error)
        }
    }

    private static func processVideo(downloadUrl: String, req: Request) -> EventLoopFuture<String> {
        let currentDirectory = FileManager.default.currentDirectoryPath
        let tempDirectory = "\(currentDirectory)/temporaryvideoFiles"
        
        if !FileManager.default.fileExists(atPath: tempDirectory) {
            try? FileManager.default.createDirectory(atPath: tempDirectory, withIntermediateDirectories: true)
            req.logger.info("Создана директория для временных файлов: \(tempDirectory)")
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = dateFormatter.string(from: Date())
        let uniqueId = UUID().uuidString.prefix(8)
        
        let inputFilePath = "\(tempDirectory)/input_\(timestamp)_\(uniqueId).mp4"
        let outputFilePath = "\(tempDirectory)/output_\(timestamp)_\(uniqueId).mp4"

        req.logger.info("Начинаем скачивание видео...")
        req.logger.info("Путь для входного файла: \(inputFilePath)")
        req.logger.info("Путь для выходного файла: \(outputFilePath)")

        return req.client.get(URI(string: downloadUrl)).flatMap { response -> EventLoopFuture<String> in
            req.logger.info("Скачиваем видео по URL: \(downloadUrl)")
            guard response.status == HTTPStatus.ok, let body = response.body else {
                req.logger.error("Ошибка скачивания видео: \(response.status)")
                return req.eventLoop.makeFailedFuture(Abort(.internalServerError, reason: "Не удалось скачать видео"))
            }
            do {
                let data = body.getData(at: 0, length: body.readableBytes) ?? Data()
                try data.write(to: URL(fileURLWithPath: inputFilePath))
                req.logger.info("Видео успешно скачано по пути: \(inputFilePath)")
                
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: inputFilePath)[.size] as? Int) ?? 0
                req.logger.info("Размер видео: \(fileSize) байт")
                if fileSize > 50 * 1024 * 1024 {
                    // try? FileManager.default.removeItem(atPath: inputFilePath) // Закомментировано
                    req.logger.error("Файл слишком большой: \(fileSize) байт")
                    req.logger.info("Входной файл оставлен: \(inputFilePath)")
                    return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Файл слишком большой!"))
                }

                let duration = getVideoDuration(inputFilePath)
                req.logger.info("Длительность видео: \(duration) секунд")
                if duration > 59 {
                    // try? FileManager.default.removeItem(atPath: inputFilePath) // Закомментировано
                    req.logger.error("Видео слишком длинное: \(duration) секунд")
                    req.logger.info("Входной файл оставлен: \(inputFilePath)")
                    return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "Видео длиннее 59 секунд!"))
                }

                return runFFmpeg(inputFilePath: inputFilePath, outputFilePath: outputFilePath, req: req)
            } catch {
                req.logger.error("Ошибка записи файла: \(error)")
                return req.eventLoop.makeFailedFuture(error)
            }
        }
    }

    private static func runFFmpeg(inputFilePath: String, outputFilePath: String, req: Request) -> EventLoopFuture<String> {
        req.logger.info("Начинаем обработку видео через ffmpeg...")
        req.logger.info("Команда ffmpeg: ffmpeg -i \(inputFilePath) -vf scale=640:640,format=yuv420p -t 59 -b:v 512k -an -r 30 -preset fast -movflags +faststart -y \(outputFilePath)")

        let promise = req.eventLoop.makePromise(of: String.self)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = [
            "-i", inputFilePath,
            "-vf", "scale=640:640,format=yuv420p",
            "-t", "59",
            "-b:v", "512k",
          // "-an", // Удаляем аудио
            "-r", "30",
            "-preset", "fast",
            "-movflags", "+faststart", // Перемещаем метаданные в начало файла
            "-y", outputFilePath
        ]

        // Устанавливаем переменные окружения
        process.environment = ProcessInfo.processInfo.environment
        process.environment?["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        // Перенаправляем stdin в /dev/null, чтобы FFmpeg не ожидал ввода
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")

        // Используем отдельные Pipe для stdout и stderr
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Асинхронно читаем stdout
        let stdoutHandle = stdoutPipe.fileHandleForReading
        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                let outputString = String(data: data, encoding: .utf8) ?? "Не удалось декодировать stdout"
                req.logger.info("FFmpeg stdout (поток): \(outputString)")
            }
        }

        // Асинхронно читаем stderr
        let stderrHandle = stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                let outputString = String(data: data, encoding: .utf8) ?? "Не удалось декодировать stderr"
                req.logger.info("FFmpeg stderr (поток): \(outputString)")
            }
        }

        // Логируем время начала
        let startTime = Date()
        req.logger.info("Время начала FFmpeg: \(startTime)")

        // Создаём задачу с таймаутом
        let timeoutTask = req.eventLoop.scheduleTask(in: .seconds(30)) {
            process.terminate()
            req.logger.error("FFmpeg не завершился за 30 секунд, процесс принудительно остановлен")
            promise.fail(Abort(.internalServerError, reason: "FFmpeg timed out"))
        }

        process.terminationHandler = { _ in
            // Отменяем таймер, если процесс завершился
            timeoutTask.cancel()

            // Закрываем обработчики чтения
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil

            let endTime = Date()
            let duration = endTime.timeIntervalSince(startTime)
            req.logger.info("Время завершения FFmpeg: \(endTime), длительность: \(duration) секунд")
            
            req.logger.info("Ожидаем завершения FFmpeg... Завершено.")

            if process.terminationStatus == 0 {
                // try? FileManager.default.removeItem(atPath: inputFilePath) // Закомментировано
                req.logger.info("Входной файл оставлен: \(inputFilePath)")
                req.logger.info("Видео успешно обработано и сохранено по пути: \(outputFilePath)")
                promise.succeed(outputFilePath)
            } else {
                // try? FileManager.default.removeItem(atPath: inputFilePath) // Закомментировано
                // try? FileManager.default.removeItem(atPath: outputFilePath) // Закомментировано
                req.logger.error("Ошибка при обработке видео через ffmpeg. Код: \(process.terminationStatus)")
                req.logger.info("Входной файл оставлен: \(inputFilePath)")
                req.logger.info("Выходной файл оставлен (если создан): \(outputFilePath)")
                promise.fail(Abort(.internalServerError, reason: "Ошибка при обработке видео через ffmpeg"))
            }
        }

        req.logger.info("Запускаем FFmpeg...")
        do {
            try process.run()
            req.logger.info("FFmpeg успешно запущен")
        } catch {
            // Отменяем таймер в случае ошибки запуска
            timeoutTask.cancel()
            req.logger.error("Ошибка запуска FFmpeg: \(error)")
            promise.fail(error)
        }
        
        return promise.futureResult
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
        let url = URI(string: "https://api.telegram.org/bot\(botToken)/sendVideoNote?return_errors=true")

        req.logger.info("Читаем файл перед отправкой...")
        guard let videoData = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            req.logger.error("Не удалось прочитать обработанный файл: \(filePath)")
            return req.eventLoop.makeFailedFuture(Abort(.internalServerError, reason: "Не удалось прочитать файл"))
        }
        req.logger.info("Размер обработанного видео: \(videoData.count) байт")

        let boundary = UUID().uuidString
        var body = ByteBufferAllocator().buffer(capacity: 0)
        
        // Добавляем chat_id
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n")
        body.writeString("\(chatId)\r\n")
        
        // Добавляем video_note
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"video_note\"; filename=\"video.mp4\"\r\n")
        body.writeString("Content-Type: video/mp4\r\n\r\n")
        body.writeBytes(videoData)
        body.writeString("\r\n")
        
        // Закрываем boundary
        body.writeString("--\(boundary)--\r\n")

        // Логируем тело запроса для отладки
        let bodyString = String(buffer: body).replacingOccurrences(of: "\r\n", with: "\n")
        req.logger.info("Тело запроса multipart/form-data:\n\(bodyString)")

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "multipart/form-data; boundary=\(boundary)")

        req.logger.info("Отправляем видеокружок в Telegram...")
        
        return req.client.post(url, headers: headers) { post in
            post.body = body
        }.map { clientResponse in
            req.logger.info("Получен ответ от Telegram API. Статус: \(clientResponse.status)")
            if let responseBody = clientResponse.body {
                let responseString = String(buffer: responseBody)
                req.logger.info("Тело ответа: \(responseString)")
            } else {
                req.logger.info("Тело ответа пустое")
            }
            
            if clientResponse.status == HTTPStatus.ok {
                try? FileManager.default.removeItem(atPath: filePath)
                req.logger.info("Выходной файл удалён после успешной отправки: \(filePath)")
            } else {
                req.logger.warning("Файл не удалён, так как отправка не удалась: \(filePath)")
            }
            
            return Response(status: clientResponse.status, headers: clientResponse.headers, body: Response.Body(buffer: clientResponse.body ?? ByteBuffer()))
        }.flatMapError { error in
            req.logger.error("Ошибка при отправке видео: \(error)")
            req.logger.info("Выходной файл сохранён для отладки: \(filePath)")
            return req.eventLoop.makeFailedFuture(error)
        }
    }
}