import Vapor
import Foundation

actor VoiceMessageRateLimiter {
    private var requests: [Int64: [Date]] = [:]
    private let maxRequests: Int
    private let timeWindow: TimeInterval
    
    init(maxRequests: Int, timeWindow: TimeInterval) {
        self.maxRequests = maxRequests
        self.timeWindow = timeWindow
    }
    
    func consume(for userId: Int64) -> Bool {
        let now = Date()
        let start = now.addingTimeInterval(-timeWindow)
        var userRequests = requests[userId] ?? []
        userRequests.removeAll { $0 < start }
        guard userRequests.count < maxRequests else {
            requests[userId] = userRequests
            return false
        }
        userRequests.append(now)
        requests[userId] = userRequests
        return true
    }
}

final class GSForTextBotController {
    private static let maxVoiceDurationSeconds = 120
    private static let voiceRateLimiter = VoiceMessageRateLimiter(maxRequests: 1, timeWindow: 60)
    private let app: Application
    private let botToken: String
    
    init(app: Application) {
        self.app = app
        self.botToken = Environment.get("GSFORTEXTBOT_TOKEN") ?? ""
    }
    
    func handleWebhook(_ req: Request) async throws -> Response {
        guard botToken.isEmpty == false else {
            req.logger.error("GSForTextBotController: GSFORTEXTBOT_TOKEN is not configured")
            return Response(status: .ok)
        }
        
        let update: GSForTextBotUpdate
        do {
            update = try req.content.decode(GSForTextBotUpdate.self)
        } catch {
            req.logger.error("GSForTextBotController: failed to decode update: \(error)")
            return Response(status: .ok)
        }
        
        guard let message = update.message ?? update.edited_message else {
            return Response(status: .ok)
        }
        
        guard let from = message.from else {
            // Без информации о пользователе не можем проверить подписку
            return Response(status: .ok)
        }
        
        // Регистрируем пользователя в общей базе монетизации
        MonetizationService.registerUser(
            botName: "gsfortextbot",
            chatId: message.chat.id,
            logger: req.logger,
            env: req.application.environment
        )
        
        let incomingText = message.text ?? ""
        
        // Если пользователь нажал кнопку "Я подписался, проверить" —
        // повторно проверяем подписку и либо разблокируем, либо снова показываем требование.
        if incomingText == "✅ Я подписался, проверить" {
            let (allowed, channels) = await MonetizationService.checkAccess(
                botName: "gsfortextbot",
                userId: from.id,
                logger: req.logger,
                env: req.application.environment,
                client: req.client
            )
            
            struct KeyboardButton: Content {
                let text: String
            }
            
            struct ReplyKeyboardMarkup: Content {
                let keyboard: [[KeyboardButton]]
                let resize_keyboard: Bool
                let one_time_keyboard: Bool
            }
            
            struct AccessPayloadWithKeyboard: Content {
                let chat_id: Int64
                let text: String
                let disable_web_page_preview: Bool
                let reply_markup: ReplyKeyboardMarkup?
            }
            
            struct ReplyKeyboardRemove: Content {
                let remove_keyboard: Bool
            }
            
            struct AccessPayloadWithRemoveKeyboard: Content {
                let chat_id: Int64
                let text: String
                let disable_web_page_preview: Bool
                let reply_markup: ReplyKeyboardRemove?
            }
            
            if allowed {
                // Удаляем клавиатуру "✅ Я подписался, проверить" после успешной проверки
                let removeKeyboard = ReplyKeyboardRemove(remove_keyboard: true)
                let removePayload = AccessPayloadWithRemoveKeyboard(
                    chat_id: message.chat.id,
                    text: "Подписка подтверждена ✅\n\nМожешь отправить голосовое или аудио, и я пришлю текстовую расшифровку",
                    disable_web_page_preview: false,
                    reply_markup: removeKeyboard
                )
                
                let sendMessageUrl = URI(string: "https://api.telegram.org/bot\(botToken)/sendMessage")
                _ = try await req.client.post(sendMessageUrl) { sendReq in
                    try sendReq.content.encode(removePayload, as: .json)
                }.get()
                
                return Response(status: .ok)
            } else {
                let channelsText: String
                if channels.isEmpty {
                    channelsText = ""
                } else {
                    let listed = channels.map { "@\($0)" }.joined(separator: "\n")
                    channelsText = "\n\nПодпишись, пожалуйста, на спонсорские каналы:\n\(listed)"
                }
                
                let text = "Я всё ещё не вижу активную подписку.\n\nЧтобы воспользоваться ботом, нужна подписка на спонсорские каналы.\(channelsText)"
                let keyboard = ReplyKeyboardMarkup(
                    keyboard: [[KeyboardButton(text: "✅ Я подписался, проверить")]],
                    resize_keyboard: true,
                    one_time_keyboard: false
                )
                let payload = AccessPayloadWithKeyboard(
                    chat_id: message.chat.id,
                    text: text,
                    disable_web_page_preview: false,
                    reply_markup: keyboard
                )
                
                let sendMessageUrl = URI(string: "https://api.telegram.org/bot\(botToken)/sendMessage")
                _ = try await req.client.post(sendMessageUrl) { sendReq in
                    try sendReq.content.encode(payload, as: .json)
                }.get()
                
                return Response(status: .ok)
            }
        }
        
        // Обработка команды /start - приветствие без проверки подписки
        if let text = message.text, text.trimmingCharacters(in: .whitespacesAndNewlines) == "/start" {
            try await sendWelcomeMessage(on: req, chatId: message.chat.id)
            return Response(status: .ok)
        }
        
        // Проверка подписки только при отправке голосовых/аудио сообщений
        if let voice = message.voice {
            try await processVoiceMessage(on: req, voice: voice, chatId: message.chat.id, userId: from.id)
            return Response(status: .ok)
        }
        
        if let audio = message.audio {
            try await processAudioMessage(on: req, audio: audio, chatId: message.chat.id, userId: from.id)
            return Response(status: .ok)
        }
        
        if let text = message.text, text.isEmpty == false {
            try await sendMessage(on: req, chatId: message.chat.id, text: "Отправь мне голосовое сообщение или аудио, и я пришлю текстовую расшифровку")
        }
        
        return Response(status: .ok)
    }
    
    private func processVoiceMessage(on req: Request, voice: TelegramVoice, chatId: Int64, userId: Int64) async throws {
        // Проверка подписки перед обработкой голосового
        let (allowed, channels) = await MonetizationService.checkAccess(
            botName: "gsfortextbot",
            userId: userId,
            logger: req.logger,
            env: req.application.environment,
            client: req.client
        )
        
        if !allowed {
            try await sendSubscriptionRequest(on: req, chatId: chatId, channels: channels)
            return
        }
        
        if let duration = voice.duration, duration > Self.maxVoiceDurationSeconds {
            try await sendMessage(on: req,
                                  chatId: chatId,
                                  text: "Голосовое длиннее 2 минут. Пожалуйста, отправь запись до двух минут")
            return
        }
        let rateLimitAllowed = await Self.voiceRateLimiter.consume(for: chatId)
        if rateLimitAllowed == false {
            try await sendMessage(on: req,
                                  chatId: chatId,
                                  text: "Я могу обрабатывать по одному голосовому в минуту. Подожди чуть-чуть и попробуй снова")
            return
        }
        let description = "voice file \(voice.file_id)"
        try await sendChatAction(on: req, chatId: chatId, action: "typing")
        do {
            let file = try await fetchTelegramFile(on: req, fileId: voice.file_id, description: description)
            let contentType = resolvedContentType(primary: voice.mime_type, filePath: file.file_path)
            try await transcribeAndReply(
                on: req,
                chatId: chatId,
                filePath: file.file_path,
                contentType: contentType,
                description: description
            )
        } catch let abort as AbortError {
            req.logger.error("GSForTextBotController: voice processing aborted: \(abort.reason)")
            try await sendMessage(on: req, chatId: chatId, text: "Не смогла обработать голосовое 😔 Попробуй ещё раз.")
        } catch {
            req.logger.error("GSForTextBotController: voice processing error: \(error)")
            try await sendMessage(on: req, chatId: chatId, text: "Произошла ошибка при расшифровке голосового, мой хороший. Попробуй ещё раз чуть позже 💕")
        }
    }
    
    private func processAudioMessage(on req: Request, audio: TelegramAudio, chatId: Int64, userId: Int64) async throws {
        // Проверка подписки перед обработкой аудио
        let (allowed, channels) = await MonetizationService.checkAccess(
            botName: "gsfortextbot",
            userId: userId,
            logger: req.logger,
            env: req.application.environment,
            client: req.client
        )
        
        if !allowed {
            try await sendSubscriptionRequest(on: req, chatId: chatId, channels: channels)
            return
        }
        
        if let duration = audio.duration, duration > Self.maxVoiceDurationSeconds {
            try await sendMessage(on: req,
                                  chatId: chatId,
                                  text: "Аудиофайл длиннее 2 минут. Присылай записи до двух минут, пожалуйста 💕")
            return
        }
        let rateLimitAllowed = await Self.voiceRateLimiter.consume(for: chatId)
        if rateLimitAllowed == false {
            try await sendMessage(on: req,
                                  chatId: chatId,
                                  text: "У меня лимит — одно голосовое в минуту. Давай чуть позже 💕")
            return
        }
        let description = "audio file \(audio.file_id)"
        try await sendChatAction(on: req, chatId: chatId, action: "typing")
        do {
            let file = try await fetchTelegramFile(on: req, fileId: audio.file_id, description: description)
            let contentType = resolvedContentType(primary: audio.mime_type, filePath: file.file_path)
            try await transcribeAndReply(
                on: req,
                chatId: chatId,
                filePath: file.file_path,
                contentType: contentType,
                description: description
            )
        } catch let abort as AbortError {
            req.logger.error("GSForTextBotController: audio processing aborted: \(abort.reason)")
            try await sendMessage(on: req, chatId: chatId, text: "Не получилось обработать аудио 😔 Попробуем ещё раз?")
        } catch {
            req.logger.error("GSForTextBotController: audio processing error: \(error)")
            try await sendMessage(on: req, chatId: chatId, text: "Что-то пошло не так при расшифровке аудио. Попробуй ещё раз, мой милый 💕")
        }
    }
    
    private func transcribeAndReply(
        on req: Request,
        chatId: Int64,
        filePath: String?,
        contentType: String,
        description: String
    ) async throws {
        guard let filePath else {
            throw Abort(.badRequest, reason: "Telegram file path is missing for \(description)")
        }
        
        let tempURL = try await downloadTelegramFile(on: req, filePath: filePath, description: description)
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }
        
        let audioData = try Data(contentsOf: tempURL)
        let recognitionService = req.application.saluteSpeechRecognitionService
        let transcript = try await recognitionService.recognize(audioData: audioData, mimeType: contentType, logger: req.logger)
        let answer = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.isEmpty {
            try await sendMessage(on: req, chatId: chatId, text: "Я получила пустой результат. Попробуй записать голосовое ещё раз, пожалуйста 💕")
        } else {
            try await sendMessage(on: req, chatId: chatId, text: answer)
        }
    }
    
    private func fetchTelegramFile(on req: Request, fileId: String, description: String) async throws -> TelegramFile {
        let url = URI(string: "https://api.telegram.org/bot\(botToken)/getFile?file_id=\(fileId)")
        let response = try await req.client.get(url)
        guard response.status == .ok else {
            req.logger.error("GSForTextBotController: failed to get file info for \(description), status=\(response.status)")
            throw Abort(.internalServerError, reason: "Telegram вернул ошибку при получении файла")
        }
        guard var body = response.body,
              let data = body.readData(length: body.readableBytes) else {
            throw Abort(.internalServerError, reason: "Не удалось прочитать ответ Telegram при получении файла")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        let fileResponse: TelegramFileResponse
        do {
            fileResponse = try decoder.decode(TelegramFileResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? ""
            req.logger.error("GSForTextBotController: не удалось декодировать ответ getFile (\(raw)) error: \(error)")
            throw Abort(.internalServerError, reason: "Telegram не прислал информацию о файле")
        }
        guard fileResponse.ok, let file = fileResponse.result else {
            let reason = fileResponse.description ?? "Telegram вернул пустой объект файла"
            req.logger.error("GSForTextBotController: getFile ответил ok=\(fileResponse.ok), описание: \(reason)")
            throw Abort(.internalServerError, reason: "Telegram не вернул путь к файлу: \(reason)")
        }
        return file
    }
    
    private func downloadTelegramFile(on req: Request, filePath: String, description: String) async throws -> URL {
        let downloadURL = URI(string: "https://api.telegram.org/file/bot\(botToken)/\(filePath)")
        let response = try await req.client.get(downloadURL)
        guard response.status == .ok else {
            req.logger.error("GSForTextBotController: failed to download \(description), status=\(response.status)")
            throw Abort(.internalServerError, reason: "Telegram вернул ошибку при скачивании файла")
        }
        guard var body = response.body,
              let data = body.readData(length: body.readableBytes) else {
            throw Abort(.internalServerError, reason: "Не удалось прочитать тело ответа при скачивании файла")
        }
        let tempDirectory = FileManager.default.temporaryDirectory
        let filename = "gs-voice-\(UUID().uuidString).\(URL(fileURLWithPath: filePath).pathExtension)"
        let tempURL = tempDirectory.appendingPathComponent(filename)
        try data.write(to: tempURL)
        return tempURL
    }
    
    private func sendWelcomeMessage(on req: Request, chatId: Int64) async throws {
        let hello = """
        Привет, мой хороший! 💕
        
        Я превращаю голосовые и аудио в текст. Просто перешли мне голосовое из любого чата или отправь своё — и через пару секунд я пришлю расшифровку.
        """
        try await sendMessage(on: req, chatId: chatId, text: hello)
    }
    
    private func sendSubscriptionRequest(on req: Request, chatId: Int64, channels: [String]) async throws {
        struct KeyboardButton: Content {
            let text: String
        }
        
        struct ReplyKeyboardMarkup: Content {
            let keyboard: [[KeyboardButton]]
            let resize_keyboard: Bool
            let one_time_keyboard: Bool
        }
        
        struct AccessPayloadWithKeyboard: Content {
            let chat_id: Int64
            let text: String
            let disable_web_page_preview: Bool
            let reply_markup: ReplyKeyboardMarkup?
        }
        
        let channelsText: String
        if channels.isEmpty {
            channelsText = ""
        } else {
            let listed = channels.map { "@\($0)" }.joined(separator: "\n")
            channelsText = "\n\nПодпишись, пожалуйста, на спонсорские каналы:\n\(listed)"
        }
        
        let text = "Чтобы воспользоваться ботом, нужна подписка на спонсорские каналы.\nПосле подписки нажми кнопку «✅ Я подписался, проверить».\(channelsText)"
        let keyboard = ReplyKeyboardMarkup(
            keyboard: [[KeyboardButton(text: "✅ Я подписался, проверить")]],
            resize_keyboard: true,
            one_time_keyboard: false
        )
        let payload = AccessPayloadWithKeyboard(
            chat_id: chatId,
            text: text,
            disable_web_page_preview: false,
            reply_markup: keyboard
        )
        
        let sendMessageUrl = URI(string: "https://api.telegram.org/bot\(botToken)/sendMessage")
        _ = try await req.client.post(sendMessageUrl) { sendReq in
            try sendReq.content.encode(payload, as: .json)
        }.get()
    }
    
    private func sendMessage(on req: Request, chatId: Int64, text: String) async throws {
        let payload = TelegramSendMessageRequest(chat_id: chatId, text: text)
        let url = URI(string: "https://api.telegram.org/bot\(botToken)/sendMessage")
        let encoder = JSONEncoder()
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")
        let response = try await req.client.post(url, headers: headers) { request in
            let data = try encoder.encode(payload)
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            request.body = .init(buffer: buffer)
        }
        if response.status != .ok {
            req.logger.warning("GSForTextBotController: sendMessage returned status \(response.status)")
        }
    }
    
    private func sendChatAction(on req: Request, chatId: Int64, action: String) async throws {
        let payload = TelegramChatActionRequest(chat_id: chatId, action: action)
        let url = URI(string: "https://api.telegram.org/bot\(botToken)/sendChatAction")
        let encoder = JSONEncoder()
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")
        _ = try await req.client.post(url, headers: headers) { request in
            let data = try encoder.encode(payload)
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            request.body = .init(buffer: buffer)
        }
    }
    
    private func resolvedContentType(primary: String?, filePath: String?) -> String {
        if let primary, primary.isEmpty == false {
            if primary.contains("ogg"), primary.contains("codecs") == false {
                return primary + ";codecs=opus"
            }
            return primary
        }
        guard let filePath else {
            return "audio/ogg;codecs=opus"
        }
        let ext = URL(fileURLWithPath: filePath).pathExtension.lowercased()
        switch ext {
        case "ogg", "oga":
            return "audio/ogg;codecs=opus"
        case "mp3":
            return "audio/mpeg"
        case "wav":
            return "audio/x-pcm;bit=16;rate=16000"
        default:
            return "audio/ogg;codecs=opus"
        }
    }
}

private struct TelegramSendMessageRequest: Content {
    let chat_id: Int64
    let text: String
}

private struct TelegramChatActionRequest: Content {
    let chat_id: Int64
    let action: String
}
