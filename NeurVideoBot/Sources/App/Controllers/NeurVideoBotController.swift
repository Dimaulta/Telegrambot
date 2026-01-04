import Vapor

final class NeurVideoBotController {
    private let botToken: String
    private let videoService: VideoGenerationService

    init() {
        self.botToken = Environment.get("NEURVIDEOBOT_TOKEN") ?? ""
        self.videoService = VideoGenerationService()
    }

    func handleWebhook(_ req: Request) async throws -> Response {
        guard botToken.isEmpty == false else {
            req.logger.error("NEURVIDEOBOT_TOKEN is not configured")
            return Response(status: .ok)
        }

        let update: NeurVideoBotUpdate
        do {
            update = try req.content.decode(NeurVideoBotUpdate.self)
        } catch {
            req.logger.error("NeurVideoBotController: failed to decode update: \(error)")
            return Response(status: .ok)
        }

        guard let message = update.message ?? update.edited_message else {
            return Response(status: .ok)
        }

        let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard text.isEmpty == false else {
            return Response(status: .ok)
        }

        let chatId = message.chat.id

        if text == "/start" {
            try await sendWelcomeMessage(on: req, chatId: chatId)
            return Response(status: .ok)
        }

        try await sendChatAction(on: req, chatId: chatId, action: "upload_video")
        try await sendMessage(
            on: req,
            chatId: chatId,
            text: "Устроюсь поудобнее и закажу видео по твоему описанию, мой хороший 🎬"
        )

        do {
            let result = try await videoService.generateVideo(prompt: text, on: req)
            let caption: String
            if let provided = result.caption, provided.isEmpty == false {
                caption = provided
            } else if let status = result.status, status.isEmpty == false {
                caption = "Готово! Статус запроса: \(status)"
            } else {
                caption = "Готово! Надеюсь, тебе понравится 💕"
            }
            try await sendVideo(on: req, chatId: chatId, videoURL: result.videoURL, caption: caption)
        } catch let abortError as AbortError {
            req.logger.error("NeurVideoBotController: API error \(abortError.reason)")
            try? await sendMessage(
                on: req,
                chatId: chatId,
                text: "Не получилось получить видео: \(abortError.reason). Попробуешь ещё раз, мой милый?"
            )
        } catch {
            req.logger.error("NeurVideoBotController: unexpected error \(error)")
            try? await sendMessage(
                on: req,
                chatId: chatId,
                text: "Что-то пошло не так, мой хороший. Попробуй ещё раз чуть позже 💔"
            )
        }

        return Response(status: .ok)
    }

    private func sendWelcomeMessage(on req: Request, chatId: Int64) async throws {
        let text = """
        Привет, мой хороший! 💕

        Я делаю видео по твоим текстовым описаниям через внешний сервис. Просто расскажи, какое видео хочешь получить, и я пришлю ссылку или файл, как только оно будет готово.
        """
        try await sendMessage(on: req, chatId: chatId, text: text)
    }

    private func sendMessage(on req: Request, chatId: Int64, text: String) async throws {
        struct SendMessageRequest: Content {
            let chat_id: Int64
            let text: String
        }

        let payload = SendMessageRequest(chat_id: chatId, text: text)
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
            req.logger.warning("NeurVideoBotController: sendMessage returned status \(response.status.code)")
        }
    }

    private func sendVideo(on req: Request, chatId: Int64, videoURL: String, caption: String?) async throws {
        struct SendVideoRequest: Content {
            let chat_id: Int64
            let video: String
            let caption: String?
        }

        let payload = SendVideoRequest(chat_id: chatId, video: videoURL, caption: caption)
        let url = URI(string: "https://api.telegram.org/bot\(botToken)/sendVideo")
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
            req.logger.warning("NeurVideoBotController: sendVideo returned status \(response.status.code)")
            try await sendMessage(
                on: req,
                chatId: chatId,
                text: "Видео сгенерировалось, но Telegram не принял ссылку. Вот она напрямую: \(videoURL)"
            )
        }
    }

    private func sendChatAction(on req: Request, chatId: Int64, action: String) async throws {
        struct ChatActionRequest: Content {
            let chat_id: Int64
            let action: String
        }

        let payload = ChatActionRequest(chat_id: chatId, action: action)
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
}

