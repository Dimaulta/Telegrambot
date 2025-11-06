import Vapor
import Foundation

final class NowmttBotController {
    func handleWebhook(_ req: Request) async throws -> Response {
        req.logger.info("═══════════════════════════════════════════════")
        req.logger.info("🔔 NowmttBot webhook hit!")
        req.logger.info("Method: \(req.method), Path: \(req.url.path)")
        
        let token = Environment.get("NOWMTTBOT_TOKEN")
        guard let token = token, token.isEmpty == false else {
            req.logger.error("NOWMTTBOT_TOKEN is missing")
            return Response(status: .internalServerError)
        }

        let rawBody = req.body.string ?? ""
        req.logger.info("📦 Raw body length: \(rawBody.count) characters")
        if rawBody.count > 0 && rawBody.count < 500 {
            req.logger.debug("Raw body: \(rawBody)")
        }

        req.logger.info("🔍 Decoding NowmttBotUpdate...")
        let update = try? req.content.decode(NowmttBotUpdate.self)
        if update == nil { 
            req.logger.error("❌ Failed to decode NowmttBotUpdate - check raw body above")
            return Response(status: .ok)
        }
        req.logger.info("✅ NowmttBotUpdate decoded successfully")

        guard let message = update?.message else {
            req.logger.warning("⚠️ No message in update (update_id: \(update?.update_id ?? -1))")
            return Response(status: .ok)
        }
        
        let text = message.text ?? ""
        req.logger.info("📨 Incoming message - chatId=\(message.chat.id), text length=\(text.count)")
        if !text.isEmpty {
            req.logger.info("📝 Message text: \(text.prefix(200))")
        }

        // Обработка команды /start
        if text == "/start" {
            req.logger.info("✅ Command /start received")
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: message.chat.id,
                text: "Привет! 👋\n\nЯ бот для скачивания TikTok видео без водяного знака! 🎬\n\nПросто отправь мне ссылку на TikTok видео, и я верну его тебе без ватермарки.\n\nПоддерживаются ссылки:\n• https://www.tiktok.com/...\n• https://vm.tiktok.com/...\n• https://vt.tiktok.com/...",
                client: req.client
            )
            return Response(status: .ok)
        }

        // Проверяем наличие TikTok URL в сообщении
        guard let tiktokUrl = extractTikTokURL(from: text) else {
            req.logger.info("ℹ️ No TikTok URL found in message (text: \(text.prefix(100)))")
            // Отправляем сообщение с инструкцией, если это не ссылка и не команда
            if !text.isEmpty && !text.hasPrefix("/") {
                _ = try? await sendTelegramMessage(
                    token: token,
                    chatId: message.chat.id,
                    text: "Привет! 👋 Отправь мне ссылку на TikTok видео, и я верну его без водяного знака! 🎬",
                    client: req.client
                )
            }
            return Response(status: .ok)
        }
        
        req.logger.info("✅ Detected TikTok URL: \(tiktokUrl)")

        // Выполняем обработку синхронно (Telegram допускает до 60 сек)
        let chatId = message.chat.id
        let client = req.client
        let logger = req.logger

        do {
            logger.info("🚀 Processing TikTok URL: \(tiktokUrl)")
            logger.info("🔧 Extracting video URL via resolver...")
            let directVideoUrl = try await extractTikTokVideoUrl(from: tiktokUrl, req: req)
            logger.info("✅ Video URL extracted: \(directVideoUrl.prefix(200))...")

            try await sendTelegramVideoByUrl(
                token: token,
                chatId: chatId,
                videoUrl: directVideoUrl,
                client: client,
                logger: logger
            )
            logger.info("✅ Video sent successfully")
        } catch {
            logger.error("❌ Error processing TikTok video: \(error)")
            _ = try? await sendTelegramMessage(
                token: token,
                chatId: chatId,
                text: "😔 Произошла ошибка при обработке видео. Попробуй ещё раз, мой хороший 💕",
                client: client
            )
        }
        
        return Response(status: .ok)
    }
    
    // Извлечение TikTok URL из текста
    private func extractTikTokURL(from text: String) -> String? {
        let patterns = [
            "https://www\\.tiktok\\.com/[^\\s]+",
            "https://vm\\.tiktok\\.com/[^\\s]+",
            "https://vt\\.tiktok\\.com/[^\\s]+",
            "https://tiktok\\.com/[^\\s]+"
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range, in: text) {
                return String(text[range])
            }
        }
        return nil
    }
    
    // Извлечение прямого URL на видео без водяного знака через резолвер
    private func extractTikTokVideoUrl(from url: String, req: Request) async throws -> String {
        let resolver = TikTokResolver(client: req.client, logger: req.logger)
        return try await resolver.resolveDirectVideoUrl(from: url)
    }
    
    // Отправка сообщения в Telegram (GET с query)
    private func sendTelegramMessage(token: String, chatId: Int64, text: String, client: Client) async throws {
        let encodedText = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage?chat_id=\(chatId)&text=\(encodedText)")
        _ = try await client.get(url)
    }
    
    // Отправка видео по прямой ссылке через Telegram API
    private func sendTelegramVideoByUrl(token: String, chatId: Int64, videoUrl: String, client: Client, logger: Logger) async throws {
        let url = URI(string: "https://api.telegram.org/bot\(token)/sendVideo")
        let boundary = UUID().uuidString
        var body = ByteBufferAllocator().buffer(capacity: 0)
        
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n")
        body.writeString("\(chatId)\r\n")
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"video\"\r\n\r\n")
        body.writeString("\(videoUrl)\r\n")
        body.writeString("--\(boundary)--\r\n")
        
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "multipart/form-data; boundary=\(boundary)")
        
        var request = ClientRequest(method: .POST, url: url)
        request.headers = headers
        request.body = body
        let response = try await client.send(request)
        
        guard response.status == .ok else {
            if let responseBody = response.body {
                let errorData = responseBody.getData(at: 0, length: responseBody.readableBytes) ?? Data()
                if let errorStr = String(data: errorData, encoding: .utf8) {
                    logger.error("Telegram API error: \(errorStr)")
                    throw Abort(.badRequest, reason: "Failed to send video: \(errorStr)")
                }
            }
            throw Abort(.badRequest, reason: "Failed to send video")
        }
        
        logger.info("✅ Video sent via Telegram API")
    }
}

