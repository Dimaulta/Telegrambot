import Vapor

enum TelegramClient {
    static func sendMessage(token: String, chatId: Int64, text: String, client: Client) async throws {
        let url = "https://api.telegram.org/bot\(token)/sendMessage"
        let payload = TelegramSendMessageRequest(chat_id: chatId, text: text, parse_mode: "Markdown")

        let uri = URI(string: url)
        var headers = HTTPHeaders()
        headers.contentType = .json

        var request = ClientRequest(method: .POST, url: uri)
        request.headers = headers
        try request.content.encode(payload)

        let response = try await client.send(request)

        guard response.status == .ok else {
            let body = response.body?.getString(at: 0, length: response.body?.readableBytes ?? 0, encoding: .utf8) ?? ""
            throw Abort(.badGateway, reason: "Telegram sendMessage failed with status \(response.status.code): \(body)")
        }
    }
}

private struct TelegramSendMessageRequest: Content, Sendable {
    let chat_id: Int64
    let text: String
    let parse_mode: String?
}

