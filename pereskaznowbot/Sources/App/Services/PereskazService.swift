import Vapor
import Foundation

/// Сервис для работы с OpenAI API
/// Получает краткое содержание (саммари) для YouTube видео через распознавание речи и GPT
struct PereskazService {
    static let shared = PereskazService()
    
    private let openAIApiBaseUrl = "https://api.openai.com/v1"
    
    /// Получает краткое содержание для YouTube видео через OpenAI
    /// - Parameters:
    ///   - videoUrl: URL YouTube видео
    ///   - client: HTTP клиент Vapor
    ///   - logger: Логгер
    /// - Returns: Текст саммари
    func getSummary(videoUrl: String, client: Client, logger: Logger) async throws -> String {
        guard let apiKey = Environment.get("PERESKAZ_OPENAI_SERVICE"), !apiKey.isEmpty else {
            logger.error("PERESKAZ_OPENAI_SERVICE token is missing")
            throw Abort(.internalServerError, reason: "OpenAI API key not configured")
        }
        
        logger.info("📡 Requesting summary for YouTube URL: \(videoUrl)")
        
        // Шаг 1: Получаем транскрипцию видео
        logger.info("🎬 Step 1: Getting transcript from YouTube video...")
        let transcript = try await getTranscript(videoUrl: videoUrl, client: client, logger: logger)
        logger.info("✅ Transcript received, length: \(transcript.count) characters")
        
        // Шаг 2: Создаем саммари через GPT
        logger.info("🤖 Step 2: Generating summary with GPT...")
        let summary = try await getSummaryWithGPT(transcript: transcript, apiKey: apiKey, client: client, logger: logger)
        logger.info("✅ Summary generated, length: \(summary.count)")
        
        return summary
    }
    
    /// Получает транскрипцию YouTube видео
    /// Пробует разные методы: автоматически сгенерированные субтитры, Whisper API и т.д.
    func getTranscript(videoUrl: String, client: Client, logger: Logger) async throws -> String {
        guard let videoId = extractVideoId(from: videoUrl) else {
            throw Abort(.badRequest, reason: "Could not extract video ID from URL")
        }
        
        logger.info("🎬 Extracted video ID: \(videoId)")
        
        // Метод 1: Пробуем получить автоматически сгенерированные субтитры YouTube
        logger.info("🔍 Method 1: Trying to get auto-generated YouTube subtitles...")
        if let transcript = try? await getYouTubeAutoSubtitles(videoId: videoId, client: client, logger: logger) {
            logger.info("✅ Got transcript from YouTube auto-subtitles")
            return transcript
        }
        
        // Метод 2: Пробуем получить субтитры через разные языки
        logger.info("🔍 Method 2: Trying different languages for YouTube subtitles...")
        let languages = ["ru", "en", "auto"]
        for lang in languages {
            if let transcript = try? await getYouTubeSubtitles(videoId: videoId, lang: lang, client: client, logger: logger) {
                logger.info("✅ Got transcript from YouTube (lang=\(lang))")
                return transcript
            }
        }
        
        // Метод 3: Используем Whisper API (если есть ключ OpenAI)
        logger.info("🔍 Method 3: Trying Whisper API for speech recognition...")
        if let openaiKey = Environment.get("PERESKAZ_OPENAI_SERVICE"), !openaiKey.isEmpty {
            do {
                let transcript = try await getTranscriptWithWhisper(videoId: videoId, videoUrl: videoUrl, apiKey: openaiKey, client: client, logger: logger)
                logger.info("✅ Got transcript from Whisper API")
                return transcript
            } catch {
                logger.warning("⚠️ Whisper API failed: \(error)")
            }
        }
        
        throw Abort(.badRequest, reason: "Не удалось получить транскрипцию видео. У видео нет доступных субтитров, и Whisper API не смог обработать видео.")
    }
    
    /// Получает автоматически сгенерированные субтитры YouTube
    private func getYouTubeAutoSubtitles(videoId: String, client: Client, logger: Logger) async throws -> String {
        // YouTube использует специальный формат для автоматически сгенерированных субтитров
        // Пробуем разные варианты
        let urlVariants = [
            "https://www.youtube.com/api/timedtext?v=\(videoId)&lang=auto&fmt=srv3",
            "https://www.youtube.com/api/timedtext?v=\(videoId)&lang=auto&fmt=srv1",
            "https://www.youtube.com/api/timedtext?v=\(videoId)&lang=auto",
        ]
        
        for urlString in urlVariants {
            let url = URI(string: urlString)
            do {
                var request = ClientRequest(method: .GET, url: url)
                request.headers.add(name: "User-Agent", value: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36")
                
                let response = try await client.send(request)
                if response.status == .ok,
                   let body = response.body,
                   let data = body.getData(at: 0, length: body.readableBytes),
                   let xml = String(data: data, encoding: .utf8),
                   !xml.isEmpty,
                   xml.count > 100 {
                    let transcript = parseYouTubeTranscriptXML(xml: xml)
                    if !transcript.isEmpty && transcript.count > 50 {
                        return transcript
                    }
                }
            } catch {
                logger.warning("⚠️ Failed to get auto-subtitles from \(urlString): \(error)")
            }
        }
        
        throw Abort(.badRequest, reason: "Auto-subtitles not available")
    }
    
    /// Получает субтитры YouTube для конкретного языка
    private func getYouTubeSubtitles(videoId: String, lang: String, client: Client, logger: Logger) async throws -> String {
        let urlVariants = [
            "https://www.youtube.com/api/timedtext?v=\(videoId)&lang=\(lang)&fmt=srv3",
            "https://www.youtube.com/api/timedtext?v=\(videoId)&lang=\(lang)&fmt=srv1",
            "https://www.youtube.com/api/timedtext?v=\(videoId)&lang=\(lang)",
        ]
        
        for urlString in urlVariants {
            let url = URI(string: urlString)
            do {
                var request = ClientRequest(method: .GET, url: url)
                request.headers.add(name: "User-Agent", value: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36")
                
                let response = try await client.send(request)
                if response.status == .ok,
                   let body = response.body,
                   let data = body.getData(at: 0, length: body.readableBytes),
                   let xml = String(data: data, encoding: .utf8),
                   !xml.isEmpty,
                   xml.count > 100 {
                    let transcript = parseYouTubeTranscriptXML(xml: xml)
                    if !transcript.isEmpty && transcript.count > 50 {
                        return transcript
                    }
                }
            } catch {
                logger.warning("⚠️ Failed to get subtitles (lang=\(lang)) from \(urlString): \(error)")
            }
        }
        
        throw Abort(.badRequest, reason: "Subtitles not available for lang=\(lang)")
    }
    
    /// Парсит XML транскрипцию YouTube
    private func parseYouTubeTranscriptXML(xml: String) -> String {
        var transcript = ""
        let pattern = #"<text[^>]*>([^<]+)</text>"#
        
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
            transcript = matches.compactMap { match -> String? in
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: xml) else {
                    return nil
                }
                return String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }.joined(separator: " ")
        }
        
        return transcript
    }
    
    /// Извлекает video ID из YouTube URL
    private func extractVideoId(from url: String) -> String? {
        let patterns = [
            #"youtube\.com/watch\?v=([\w-]+)"#,
            #"youtu\.be/([\w-]+)"#,
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: url) {
                return String(url[range])
            }
        }
        return nil
    }
    
    /// Создает саммари через GPT на основе транскрипции
    func getSummaryWithGPT(transcript: String, client: Client, logger: Logger) async throws -> String {
        guard let apiKey = Environment.get("PERESKAZ_OPENAI_SERVICE"), !apiKey.isEmpty else {
            logger.error("PERESKAZ_OPENAI_SERVICE token is missing")
            throw Abort(.internalServerError, reason: "OpenAI API key not configured")
        }
        
        return try await getSummaryWithGPT(transcript: transcript, apiKey: apiKey, client: client, logger: logger)
    }
    
    /// Создает саммари через GPT на основе транскрипции (внутренний метод с apiKey)
    private func getSummaryWithGPT(transcript: String, apiKey: String, client: Client, logger: Logger) async throws -> String {
        logger.info("🤖 Requesting summary from OpenAI GPT...")
        
        // Ограничиваем длину транскрипции (GPT имеет лимиты токенов)
        let maxLength = 15000 // Примерно 4000 токенов
        let truncatedTranscript = transcript.count > maxLength 
            ? String(transcript.prefix(maxLength)) + "\n\n[...текст обрезан из-за ограничений длины...]"
            : transcript
        
        let prompt = """
        Создай краткое содержание (саммари) следующего текста транскрипции YouTube видео.
        
        Требования к саммари:
        - Краткое (2-3 абзаца, максимум 500 слов)
        - Понятное и структурированное
        - На русском языке
        - Содержит основные идеи и ключевые моменты
        - Выделяет главные тезисы и выводы
        
        Транскрипция:
        \(truncatedTranscript)
        """
        
        struct OpenAIRequest: Content {
            let model: String
            let messages: [OpenAIMessage]
            let temperature: Double
        }
        
        struct OpenAIMessage: Content {
            let role: String
            let content: String
        }
        
        struct OpenAIResponse: Content {
            let choices: [Choice]
        }
        
        struct Choice: Content {
            let message: Message
        }
        
        struct Message: Content {
            let content: String
        }
        
        let url = URI(string: "\(openAIApiBaseUrl)/chat/completions")
        var request = ClientRequest(method: .POST, url: url)
        request.headers.add(name: .authorization, value: "Bearer \(apiKey)")
        request.headers.add(name: .contentType, value: "application/json")
        
        let rawModel = Environment.get("OPENAI_MODEL")?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = rawModel.isEmpty ? "gpt-4o-mini" : rawModel
        
        let payload = OpenAIRequest(
            model: model,
            messages: [
                OpenAIMessage(role: "system", content: "Ты помощник, который создает краткие содержания (саммари) для YouTube видео на русском языке. Твоя задача - выделить главные идеи и ключевые моменты из транскрипции видео."),
                OpenAIMessage(role: "user", content: prompt)
            ],
            temperature: 0.3
        )
        
        request.body = try .init(data: JSONEncoder().encode(payload))
        
        logger.info("📤 Sending request to OpenAI API...")
        let response = try await client.send(request)
        
        guard response.status == .ok else {
            let body: String
            if let responseBody = response.body {
                let data = responseBody.getData(at: 0, length: responseBody.readableBytes) ?? Data()
                body = String(data: data, encoding: .utf8) ?? "Unknown error"
            } else {
                body = "Unknown error"
            }
            logger.error("❌ OpenAI API error: \(response.status) - \(body)")
            throw Abort(.badRequest, reason: "OpenAI API error: \(response.status)")
        }
        
        let openaiResponse = try response.content.decode(OpenAIResponse.self)
        
        guard let summary = openaiResponse.choices.first?.message.content,
              !summary.isEmpty else {
            throw Abort(.badRequest, reason: "OpenAI returned empty summary")
        }
        
        return summary
    }
    
    /// Получает транскрипцию через Whisper API
    /// Скачивает аудио с YouTube и отправляет в Whisper
    private func getTranscriptWithWhisper(videoId: String, videoUrl: String, apiKey: String, client: Client, logger: Logger) async throws -> String {
        logger.info("🎤 Using Whisper API for transcription...")
        
        // Шаг 1: Скачиваем аудио с YouTube
        logger.info("📥 Step 1: Downloading audio from YouTube...")
        let downloadStartTime = Date()
        let audioData = try await downloadYouTubeAudio(videoUrl: videoUrl, videoId: videoId, logger: logger)
        let downloadElapsed = Date().timeIntervalSince(downloadStartTime)
        logger.info("✅ Audio downloaded in \(Int(downloadElapsed)) seconds, size: \(audioData.count) bytes (\(audioData.count / 1024 / 1024) MB)")
        
        // Проверяем размер файла перед отправкой
        let maxSize = 25 * 1024 * 1024 // 25MB
        if audioData.count > maxSize {
            logger.error("❌ Audio file too large: \(audioData.count) bytes (\(audioData.count / 1024 / 1024) MB), max: \(maxSize / 1024 / 1024) MB")
            throw Abort(.badRequest, reason: "Аудио файл слишком большой (\(audioData.count / 1024 / 1024) MB). Максимальный размер: 25 MB. Попробуй видео покороче.")
        }
        
        // Шаг 2: Отправляем в Whisper API
        logger.info("🤖 Step 2: Sending audio to Whisper API...")
        let whisperStartTime = Date()
        let transcript = try await transcribeWithWhisper(audioData: audioData, apiKey: apiKey, client: client, logger: logger)
        let whisperElapsed = Date().timeIntervalSince(whisperStartTime)
        logger.info("✅ Transcription received from Whisper in \(Int(whisperElapsed)) seconds, length: \(transcript.count) characters")
        
        return transcript
    }
    
    /// Скачивает аудио с YouTube используя yt-dlp (если установлен) или альтернативный метод
    private func downloadYouTubeAudio(videoUrl: String, videoId: String, logger: Logger) async throws -> Data {
        // Метод 1: Пробуем использовать yt-dlp (если установлен)
        let ytdlpPath = "/opt/homebrew/bin/yt-dlp" // macOS Homebrew путь
        let ytdlpPathAlt = "/usr/local/bin/yt-dlp" // Альтернативный путь
        
        let ytdlpPaths = [ytdlpPath, ytdlpPathAlt, "yt-dlp"]
        
        for ytdlp in ytdlpPaths {
            if FileManager.default.fileExists(atPath: ytdlp) || ytdlp == "yt-dlp" {
                logger.info("🔍 Trying yt-dlp at: \(ytdlp)")
                do {
                    let audioData = try await downloadWithYtDlp(videoUrl: videoUrl, ytdlpPath: ytdlp, logger: logger)
                    return audioData
                } catch {
                    logger.warning("⚠️ yt-dlp failed: \(error)")
                    continue
                }
            }
        }
        
        // Метод 2: Пробуем получить прямую ссылку на аудио через YouTube API
        // Это сложнее и может не работать из-за ограничений YouTube
        throw Abort(.badRequest, reason: "Не удалось скачать аудио с YouTube. Установите yt-dlp: brew install yt-dlp")
    }
    
    /// Скачивает аудио используя yt-dlp
    private func downloadWithYtDlp(videoUrl: String, ytdlpPath: String, logger: Logger) async throws -> Data {
        // Создаем временную папку для работы yt-dlp
        let tempDir = FileManager.default.temporaryDirectory
        let workDir = tempDir.appendingPathComponent(UUID().uuidString)
        
        // Создаем папку для работы
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        
        defer {
            // Удаляем всю временную папку после использования
            try? FileManager.default.removeItem(at: workDir)
        }
        
        // Создаем путь для финального аудио файла
        let audioFile = workDir.appendingPathComponent("audio.m4a")
        
        // Запускаем yt-dlp для скачивания аудио
        // Используем более низкое качество, чтобы файл был меньше 25MB (лимит Whisper API)
        // player_client=tv_simply — обход HTTP 403: YouTube требует PO Token для web-клиента; tv_simply не требует (см. yt-dlp PO-Token-Guide)
        let process = Process()
        let (executable, args): (String, [String])
        if ytdlpPath == "yt-dlp" {
            executable = "/usr/bin/env"
            args = ["yt-dlp"] + [
                "--js-runtimes", "node:/usr/bin/nodejs",
                "--extractor-args", "youtube:player_client=tv_simply",
                "--extract-audio",
                "--audio-format", "m4a",
                "--audio-quality", "7",
                "--postprocessor-args", "ffmpeg:-b:a 32k -ar 16000 -ac 1",
                "--user-agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "--output", audioFile.path,
                "--no-mtime",
                "--no-playlist",
                videoUrl
            ]
        } else {
            executable = ytdlpPath
            args = [
                "--js-runtimes", "node:/usr/bin/nodejs",
                "--extractor-args", "youtube:player_client=tv_simply",
                "--extract-audio",
                "--audio-format", "m4a",
                "--audio-quality", "7",
                "--postprocessor-args", "ffmpeg:-b:a 32k -ar 16000 -ac 1",
                "--user-agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "--output", audioFile.path,
                "--no-mtime",
                "--no-playlist",
                videoUrl
            ]
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        
        // Устанавливаем переменную окружения для временной папки (yt-dlp использует TMPDIR)
        var env = ProcessInfo.processInfo.environment
        env["TMPDIR"] = workDir.path
        process.environment = env
        
        logger.info("📥 Running yt-dlp: \(executable) \(args.joined(separator: " "))")
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw Abort(.badRequest, reason: "yt-dlp failed with status \(process.terminationStatus)")
        }
        
        guard FileManager.default.fileExists(atPath: audioFile.path),
              let audioData = try? Data(contentsOf: audioFile) else {
            throw Abort(.badRequest, reason: "Failed to read downloaded audio file")
        }
        
        logger.info("✅ Audio downloaded successfully, size: \(audioData.count) bytes")
        
        // Проверяем размер файла - Whisper API имеет лимит 25MB
        let maxSize = 25 * 1024 * 1024 // 25MB
        if audioData.count > maxSize {
            logger.warning("⚠️ Audio file too large (\(audioData.count) bytes, max: \(maxSize)), compressing...")
            // Пробуем перекодировать с еще более низким битрейтом
            let compressedData = try await compressAudio(
                audioFile: audioFile,
                workDir: workDir,
                originalSize: audioData.count,
                logger: logger
            )
            logger.info("✅ Audio compressed, new size: \(compressedData.count) bytes")
            return compressedData
        }
        
        return audioData
    }
    
    /// Отправляет аудио в Whisper API для транскрипции
    private func transcribeWithWhisper(audioData: Data, apiKey: String, client: Client, logger: Logger) async throws -> String {
        logger.info("🤖 Sending audio to Whisper API (size: \(audioData.count) bytes)...")
        
        // Whisper API требует multipart/form-data
        let boundary = UUID().uuidString
        var body = ByteBufferAllocator().buffer(capacity: 0)
        
        // Добавляем file
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n")
        body.writeString("Content-Type: audio/m4a\r\n\r\n")
        body.writeBytes(audioData)
        body.writeString("\r\n")
        
        // Добавляем model
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.writeString("whisper-1\r\n")
        
        // Добавляем language (опционально, можно указать "ru" для русского)
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
        body.writeString("ru\r\n")
        
        body.writeString("--\(boundary)--\r\n")
        
        let url = URI(string: "\(openAIApiBaseUrl)/audio/transcriptions")
        var request = ClientRequest(method: .POST, url: url)
        request.headers.add(name: .authorization, value: "Bearer \(apiKey)")
        request.headers.add(name: .contentType, value: "multipart/form-data; boundary=\(boundary)")
        request.body = .init(buffer: body)
        
        // Устанавливаем таймауты для запроса (Whisper может обрабатывать долго)
        request.timeout = .seconds(300) // 5 минут на транскрипцию
        
        logger.info("📤 Sending request to Whisper API (timeout: 300s)...")
        let startTime = Date()
        let response = try await client.send(request)
        let elapsed = Date().timeIntervalSince(startTime)
        logger.info("📥 Whisper API response received in \(Int(elapsed)) seconds")
        
        guard response.status == .ok else {
            let body: String
            if let responseBody = response.body {
                let data = responseBody.getData(at: 0, length: responseBody.readableBytes) ?? Data()
                body = String(data: data, encoding: .utf8) ?? "Unknown error"
            } else {
                body = "Unknown error"
            }
            logger.error("❌ Whisper API error: \(response.status) - \(body)")
            throw Abort(.badRequest, reason: "Whisper API error: \(response.status)")
        }
        
        struct WhisperResponse: Content {
            let text: String
        }
        
        let whisperResponse = try response.content.decode(WhisperResponse.self)
        
        guard !whisperResponse.text.isEmpty else {
            throw Abort(.badRequest, reason: "Whisper returned empty transcription")
        }
        
        logger.info("✅ Whisper transcription received, length: \(whisperResponse.text.count) characters")
        return whisperResponse.text
    }
    
    /// Сжимает аудио файл для соответствия лимиту Whisper API (25MB)
    private func compressAudio(audioFile: URL, workDir: URL, originalSize: Int, logger: Logger) async throws -> Data {
        // Используем ffmpeg для перекодирования с более низким битрейтом
        // Проверяем наличие ffmpeg
        let ffmpegPaths = ["/usr/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg", "ffmpeg"]
        var ffmpegPath: String?
        
        for path in ffmpegPaths {
            if FileManager.default.fileExists(atPath: path) || path == "ffmpeg" {
                ffmpegPath = path
                break
            }
        }
        
        guard let ffmpeg = ffmpegPath else {
            logger.warning("⚠️ ffmpeg not found, cannot compress audio")
            // Если ffmpeg нет, возвращаем оригинал (Whisper API вернет ошибку, но попробуем)
            return try Data(contentsOf: audioFile)
        }
        
        let compressedFile = workDir.appendingPathComponent("audio_compressed.m4a")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        
        // Используем более агрессивное сжатие для больших файлов
        // Более низкий битрейт и частота дискретизации для меньшего размера
        process.arguments = [
            "-i", audioFile.path,
            "-c:a", "aac", // Кодек аудио
            "-b:a", "24k", // Очень низкий битрейт (24k) для максимального сжатия
            "-ar", "16000", // Частота дискретизации (16kHz достаточно для речи)
            "-ac", "1", // Моно канал
            "-threads", "4", // Увеличиваем потоки для быстрой обработки
            "-preset", "fast", // Быстрый пресет для кодирования
            "-aac_coder", "twoloop", // Более эффективный кодер AAC
            "-y", // Перезаписать файл если существует
            compressedFile.path
        ]
        
        logger.info("🎵 Compressing audio with ffmpeg (this may take a while for large files, up to 10 minutes)...")
        
        // Запускаем процесс
        try process.run()
        
        // Увеличиваем таймаут до 10 минут для больших файлов (46 MB может занять время)
        let timeout: TimeInterval = 600 // 10 минут
        let startTime = Date()
        
        // Проверяем статус процесса асинхронно
        while process.isRunning {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > timeout {
                logger.warning("⚠️ ffmpeg compression timeout after \(Int(elapsed)) seconds, terminating...")
                process.terminate()
                // Даем процессу немного времени на завершение
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 секунды
                if process.isRunning {
                    // Принудительно завершаем процесс
                    process.terminate()
                }
                logger.warning("⚠️ Audio compression timed out, using original")
                return try Data(contentsOf: audioFile)
            }
            // Проверяем каждые 0.5 секунды
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 секунды
        }
        
        // Процесс завершился, получаем статус
        let terminationStatus = process.terminationStatus
        
        guard terminationStatus == 0,
              FileManager.default.fileExists(atPath: compressedFile.path),
              let compressedData = try? Data(contentsOf: compressedFile) else {
            logger.warning("⚠️ Audio compression failed (status: \(process.terminationStatus)), using original")
            return try Data(contentsOf: audioFile)
        }
        
        logger.info("✅ Audio compressed: \(originalSize) bytes -> \(compressedData.count) bytes")
        
        // Проверяем, что сжатый файл действительно меньше
        if compressedData.count >= originalSize {
            logger.warning("⚠️ Compressed file is not smaller (\(compressedData.count) >= \(originalSize)), using original")
            return try Data(contentsOf: audioFile)
        }
        
        // Проверяем, что сжатый файл меньше лимита Whisper API (25MB)
        let maxSize = 25 * 1024 * 1024 // 25MB
        if compressedData.count > maxSize {
            logger.warning("⚠️ Compressed file still too large (\(compressedData.count) bytes, max: \(maxSize)), trying more aggressive compression...")
            
            // Пробуем еще более агрессивное сжатие
            let moreCompressedFile = workDir.appendingPathComponent("audio_compressed2.m4a")
            let process2 = Process()
            process2.executableURL = URL(fileURLWithPath: ffmpeg)
            process2.arguments = [
                "-i", compressedFile.path,
                "-c:a", "aac",
                "-b:a", "16k", // Минимальный битрейт для речи
                "-ar", "16000",
                "-ac", "1",
                "-threads", "4",
                "-preset", "fast",
                "-aac_coder", "twoloop", // Более эффективный кодер AAC
                "-y",
                moreCompressedFile.path
            ]
            
            try process2.run()
            
            // Ждем завершения с таймаутом 5 минут
            let timeout2: TimeInterval = 300
            let startTime2 = Date()
            
            while process2.isRunning {
                let elapsed = Date().timeIntervalSince(startTime2)
                if elapsed > timeout2 {
                    logger.warning("⚠️ Second compression attempt timed out")
                    process2.terminate()
                    // Если вторая попытка не удалась, выбрасываем ошибку
                    throw Abort(.badRequest, reason: "Аудио файл слишком большой (\(compressedData.count / 1024 / 1024) MB после сжатия). Максимальный размер: 25 MB. Попробуй видео покороче.")
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            
            if process2.terminationStatus == 0,
               FileManager.default.fileExists(atPath: moreCompressedFile.path),
               let moreCompressedData = try? Data(contentsOf: moreCompressedFile),
               moreCompressedData.count < maxSize {
                logger.info("✅ Second compression successful: \(compressedData.count) bytes -> \(moreCompressedData.count) bytes")
                return moreCompressedData
            }
            
            // Если вторая попытка не помогла, выбрасываем ошибку
            throw Abort(.badRequest, reason: "Аудио файл слишком большой (\(compressedData.count / 1024 / 1024) MB после сжатия). Максимальный размер: 25 MB. Попробуй видео покороче.")
        }
        
        return compressedData
    }
}
