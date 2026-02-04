import Vapor
import Foundation

struct YouTubeShortsResolver {
    private let client: Client
    private let logger: Logger
    
    init(client: Client, logger: Logger) {
        self.client = client
        self.logger = logger
    }
    
    func resolveDirectVideoUrl(from originalUrl: String) async throws -> String {
        // Упрощенная версия: сразу используем yt-dlp (публичные API не работают и замедляют процесс)
        let trimmed = originalUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: "Empty YouTube Shorts URL")
        }
        
        let normalized = await normalizeYouTubeURL(trimmed)
        logger.info("Normalized YouTube Shorts URL: \(normalized)")
        guard normalized.contains("youtube.com/shorts/") || normalized.contains("youtu.be/") else {
            throw Abort(.badRequest, reason: "Invalid YouTube Shorts URL")
        }
        
        // Сразу используем yt-dlp (быстрее и надежнее)
        return try await resolveViaYtDlp(url: normalized)
    }
    
    private func normalizeYouTubeURL(_ url: String) async -> String {
        var current = url
        let maxRedirects = 5
        var attempts = 0
        
        while attempts < maxRedirects {
            attempts += 1
            guard URL(string: current) != nil else { break }
            
            var request = ClientRequest(method: .HEAD, url: URI(string: current))
            request.headers.add(name: "User-Agent", value: "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/537.36 (KHTML, like Gecko) VaporBot/1.0")
            
            do {
                let response = try await client.send(request)
                let status = response.status.code
                if (300...399).contains(status),
                   let location = response.headers.first(name: "Location"),
                   !location.isEmpty {
                    if location.hasPrefix("http") {
                        current = location
                    } else {
                        current = "https://www.youtube.com\(location)"
                    }
                    continue
                } else {
                    return current
                }
            } catch {
                logger.warning("Failed to normalize YouTube URL \(current): \(error.localizedDescription)")
                break
            }
        }
        return current
    }
    
    // Используем yt-dlp для получения прямого URL (быстрее и надежнее публичных API)
    private func resolveViaYtDlp(url: String) async throws -> String {
        logger.info("Trying yt-dlp for URL: \(url)")
        
        // Находим yt-dlp (универсальный поиск для Mac и Linux/VPS)
        let ytdlpPaths = [
            "/opt/homebrew/bin/yt-dlp",  // macOS Homebrew (Apple Silicon)
            "/usr/local/bin/yt-dlp",      // macOS Homebrew (Intel) / Linux
            "/usr/bin/yt-dlp",            // Linux стандартный путь
            "/bin/yt-dlp",                // Linux альтернативный путь
            "yt-dlp"                      // Через PATH (если установлен глобально)
        ]
        
        var ytDlpPath: String?
        for path in ytdlpPaths {
            if FileManager.default.fileExists(atPath: path) || path == "yt-dlp" {
                logger.info("🔍 Found yt-dlp at: \(path)")
                ytDlpPath = path
                break
            }
        }
        
        guard let ytdlp = ytDlpPath else {
            throw Abort(.badRequest, reason: "yt-dlp not found. Install it: brew install yt-dlp (Mac) or apt install yt-dlp (Linux)")
        }
        
        // Запускаем yt-dlp для получения прямого URL
        // player_client=tv,android — реже дают 403; Deno в контейнере даёт JS runtime при необходимости
        let ytDlpProcess = Process()
        ytDlpProcess.executableURL = URL(fileURLWithPath: ytdlp)
        
        ytDlpProcess.arguments = [
            "--js-runtimes", "deno:/usr/local/bin/deno",
            "--extractor-args", "youtube:player_client=tv,android",
            "--get-url",
            "--format", "bestvideo[height=1080][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height=720][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=1080][ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best",
            url
        ]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        ytDlpProcess.standardOutput = outputPipe
        ytDlpProcess.standardError = errorPipe
        
        do {
            try ytDlpProcess.run()
            ytDlpProcess.waitUntilExit()
            
            if ytDlpProcess.terminationStatus == 0 {
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !output.isEmpty,
                   output.hasPrefix("http") {
                    logger.info("✅ yt-dlp extracted URL successfully")
                    return output
                }
            } else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                if let errorStr = String(data: errorData, encoding: .utf8) {
                    logger.warning("yt-dlp error: \(errorStr)")
                }
            }
        } catch {
            logger.warning("yt-dlp execution failed: \(error.localizedDescription)")
        }
        
        throw Abort(.badRequest, reason: "yt-dlp failed to extract video URL")
    }
}
