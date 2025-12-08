import Foundation
import Vapor
import SQLite3

/// Сервис монетизации для Neurfotobot.
/// Отвечает за:
/// - регистрацию пользователей в общей базе (user_sessions)
/// - проверку необходимости подписки и факта подписки через Telegram API
enum MonetizationService {
    // MARK: - Paths

    private static func databasePath(env: Environment) -> String {
        if let fromEnv = Environment.get("MONETIZATION_DB_PATH"), fromEnv.isEmpty == false {
            return fromEnv
        }
        return "config/monetization.sqlite"
    }

    // MARK: - Public API

    /// Гарантирует, что база и таблицы существуют.
    static func ensureDatabase(app: Application) {
        let path = databasePath(env: app.environment)
        do {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
        } catch {
            app.logger.error("Failed to create directory for monetization DB (Neurfotobot): \(error.localizedDescription)")
        }

        var db: OpaquePointer?
        if sqlite3_open(path, &db) != SQLITE_OK {
            if let errorMessage = sqlite3_errmsg(db).flatMap({ String(cString: $0) }) {
                app.logger.error("Failed to open monetization DB at \(path) (Neurfotobot): \(errorMessage)")
            } else {
                app.logger.error("Failed to open monetization DB at \(path) (Neurfotobot)")
            }
            if db != nil {
                sqlite3_close(db)
            }
            return
        }

        defer {
            sqlite3_close(db)
        }

        let createUserSessionsSQL = """
        CREATE TABLE IF NOT EXISTS user_sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            bot_name TEXT NOT NULL,
            chat_id INTEGER NOT NULL,
            last_seen_at INTEGER NOT NULL,
            UNIQUE(bot_name, chat_id)
        );
        """

        let createSponsorCampaignsSQL = """
        CREATE TABLE IF NOT EXISTS sponsor_campaigns (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            bot_name TEXT NOT NULL,
            channel_username TEXT NOT NULL,
            active INTEGER NOT NULL DEFAULT 1,
            expires_at INTEGER NULL,
            created_at INTEGER NOT NULL
        );
        """

        let createBotSettingsSQL = """
        CREATE TABLE IF NOT EXISTS bot_settings (
            bot_name TEXT PRIMARY KEY,
            require_subscription INTEGER NOT NULL DEFAULT 0
        );
        """

        for sql in [createUserSessionsSQL, createSponsorCampaignsSQL, createBotSettingsSQL] {
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                if let errorMessage = sqlite3_errmsg(db).flatMap({ String(cString: $0) }) {
                    app.logger.error("Failed to run schema SQL (Neurfotobot): \(errorMessage)")
                } else {
                    app.logger.error("Failed to run schema SQL (Neurfotobot, unknown error)")
                }
            }
        }

        app.logger.info("Monetization DB ensured at path (Neurfotobot): \(path)")
    }

    /// Регистрирует/обновляет пользователя в user_sessions.
    static func registerUser(botName: String, chatId: Int64, logger: Logger, env: Environment) {
        let path = databasePath(env: env)
        var db: OpaquePointer?

        guard sqlite3_open(path, &db) == SQLITE_OK else {
            logger.error("Failed to open monetization DB for registerUser")
            if db != nil { sqlite3_close(db) }
            return
        }
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO user_sessions (bot_name, chat_id, last_seen_at)
        VALUES (?1, ?2, ?3)
        ON CONFLICT(bot_name, chat_id) DO UPDATE SET last_seen_at = excluded.last_seen_at;
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            logger.error("Failed to prepare registerUser statement")
            return
        }
        defer { sqlite3_finalize(stmt) }

        let now = Int(Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 1, (botName as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 2, chatId)
        sqlite3_bind_int(stmt, 3, Int32(now))

        if sqlite3_step(stmt) != SQLITE_DONE {
            logger.error("Failed to execute registerUser statement")
        }
    }

    struct Campaign {
        let channelUsername: String
        let expiresAt: Int?
    }

    /// Проверяет, разрешён ли доступ пользователю.
    /// Возвращает кортеж (allowed, [channels]), где channels — список активных каналов-спонсоров для сообщения пользователю.
    static func checkAccess(
        botName: String,
        userId: Int64,
        logger: Logger,
        env: Environment,
        client: Client
    ) async -> (Bool, [String]) {
        let path = databasePath(env: env)
        var db: OpaquePointer?

        guard sqlite3_open(path, &db) == SQLITE_OK else {
            logger.error("Failed to open monetization DB for checkAccess")
            if db != nil { sqlite3_close(db) }
            // Фейлим мягко: разрешаем доступ
            return (true, [])
        }
        defer { sqlite3_close(db) }

        // 1. Смотрим, включена ли вообще обязательная подписка для этого бота
        let settingSQL = """
        SELECT require_subscription
        FROM bot_settings
        WHERE bot_name = ?1;
        """

        var settingStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, settingSQL, -1, &settingStmt, nil) != SQLITE_OK {
            logger.error("Failed to prepare bot_settings in checkAccess")
            return (true, [])
        }
        defer { sqlite3_finalize(settingStmt) }

        sqlite3_bind_text(settingStmt, 1, (botName as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var requireSubscription = false
        if sqlite3_step(settingStmt) == SQLITE_ROW {
            requireSubscription = sqlite3_column_int(settingStmt, 0) != 0
        }

        logger.info("checkAccess for \(botName): require_subscription = \(requireSubscription)")

        if requireSubscription == false {
            // Подписка не обязательна — пропускаем
            logger.info("checkAccess for \(botName): подписка не обязательна, пропускаем")
            return (true, [])
        }

        // 2. Читаем активные и неистёкшие кампании
        let now = Int(Date().timeIntervalSince1970)
        let campaignsSQL = """
        SELECT channel_username, expires_at
        FROM sponsor_campaigns
        WHERE bot_name = ?1
          AND active = 1
          AND (expires_at IS NULL OR expires_at >= ?2);
        """

        var campaignsStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, campaignsSQL, -1, &campaignsStmt, nil) != SQLITE_OK {
            logger.error("Failed to prepare sponsor_campaigns in checkAccess")
            return (true, [])
        }
        defer { sqlite3_finalize(campaignsStmt) }

        sqlite3_bind_text(campaignsStmt, 1, (botName as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(campaignsStmt, 2, Int32(now))

        var campaigns: [Campaign] = []
        while sqlite3_step(campaignsStmt) == SQLITE_ROW {
            let username = String(cString: sqlite3_column_text(campaignsStmt, 0))
            let expiresAt: Int?
            if sqlite3_column_type(campaignsStmt, 1) == SQLITE_NULL {
                expiresAt = nil
            } else {
                expiresAt = Int(sqlite3_column_int(campaignsStmt, 1))
            }
            campaigns.append(Campaign(channelUsername: username, expiresAt: expiresAt))
        }

        if campaigns.isEmpty {
            // Нет активных кампаний — не блокируем пользователей
            logger.info("checkAccess for \(botName): нет активных кампаний, пропускаем")
            return (true, [])
        }

        logger.info("checkAccess for \(botName): найдено \(campaigns.count) активных кампаний: \(campaigns.map { $0.channelUsername }.joined(separator: ", "))")

        // 3. Проверяем подписку через Telegram API
        guard let checkerToken = Environment.get("SPONSOR_CHECK_BOT_TOKEN"), checkerToken.isEmpty == false else {
            logger.warning("SPONSOR_CHECK_BOT_TOKEN is not set — пропускаем проверку подписки")
            return (true, [])
        }

        let channels = campaigns.map { $0.channelUsername }

        do {
            // Стратегия: достаточно быть подписанным хотя бы на один из каналов
            for channel in channels {
                let isMember = try await isUserMember(
                    userId: userId,
                    channelUsername: channel,
                    botToken: checkerToken,
                    client: client,
                    logger: logger
                )
                logger.info("checkAccess for \(botName): пользователь \(userId) на канале @\(channel): \(isMember ? "подписан" : "не подписан")")
                if isMember {
                    logger.info("checkAccess for \(botName): пользователь \(userId) подписан хотя бы на один канал, доступ разрешён")
                    return (true, channels)
                }
            }
            // Не нашли ни одного канала, где пользователь подписан
            logger.info("checkAccess for \(botName): пользователь \(userId) не подписан ни на один из каналов, доступ запрещён")
            return (false, channels)
        } catch {
            logger.error("checkAccess for \(botName): Error while checking sponsor subscriptions: \(error.localizedDescription)")
            // При любой ошибке даём доступ, чтобы не ломать сервис
            logger.warning("checkAccess for \(botName): из-за ошибки применяем fail-open стратегию, доступ разрешён")
            return (true, [])
        }
    }

    // MARK: - Telegram API helper

    private static func isUserMember(
        userId: Int64,
        channelUsername: String,
        botToken: String,
        client: Client,
        logger: Logger
    ) async throws -> Bool {
        // Сначала получаем числовой ID канала через getChat
        // channelUsername приходит без @
        // Пробуем разные варианты регистра username
        let variants = [
            "@\(channelUsername)",           // Точно как в базе
            "@\(channelUsername.capitalized)", // С заглавной буквы
            "@\(channelUsername.lowercased())", // Все маленькие
            "@\(channelUsername.uppercased())"  // Все большие
        ]
        
        var chatId: Int64?
        var lastError: Error?
        
        for variant in variants {
            let getChatUrl = URI(string: "https://api.telegram.org/bot\(botToken)/getChat")

            struct GetChatPayload: Content {
                let chat_id: String
            }

            let getChatPayload = GetChatPayload(chat_id: variant)

            do {
                let getChatResponse = try await client.post(getChatUrl) { req in
                    try req.content.encode(getChatPayload, as: .json)
                }

                guard getChatResponse.status == .ok, let getChatBody = getChatResponse.body else {
                    logger.warning("getChat failed for \(variant), status: \(getChatResponse.status)")
                    if let body = getChatResponse.body {
                        let bodyData = body.getData(at: 0, length: body.readableBytes) ?? Data()
                        if let bodyString = String(data: bodyData, encoding: .utf8) {
                            logger.warning("getChat response body: \(bodyString)")
                        }
                    }
                    continue
                }

                struct GetChatResponse: Decodable {
                    struct Chat: Decodable {
                        let id: Int64
                    }

                    let ok: Bool
                    let result: Chat?
                }

                let getChatData = getChatBody.getData(at: 0, length: getChatBody.readableBytes) ?? Data()
                let getChatDecoded = try JSONDecoder().decode(GetChatResponse.self, from: getChatData)

                guard getChatDecoded.ok, let chat = getChatDecoded.result else {
                    if let errorString = String(data: getChatData, encoding: .utf8) {
                        logger.warning("getChat returned not ok for \(variant), response: \(errorString)")
                    } else {
                        logger.warning("getChat returned not ok for \(variant)")
                    }
                    continue
                }
                
                chatId = chat.id
                logger.info("getChat успешно для \(variant), получен ID: \(chat.id)")
                break
            } catch {
                lastError = error
                logger.debug("getChat exception for \(variant): \(error.localizedDescription)")
                continue
            }
        }
        
        // Если все варианты username не сработали, выбрасываем ошибку
        // Это означает, что бот не имеет доступа к каналу или канал не существует
        guard let finalChatId = chatId else {
            logger.warning("getChat failed for all variants of @\(channelUsername), last error: \(lastError?.localizedDescription ?? "unknown")")
            logger.warning("Убедись, что NowControllerBot добавлен как администратор в канал @\(channelUsername)")
            throw Abort(.badRequest, reason: "getChat failed for @\(channelUsername) - проверь, что бот добавлен как админ в канал")
        }

        // Теперь используем числовой ID для getChatMember
        // Используем прямой HTTP-запрос через URLSession вместо Vapor Client,
        // потому что Vapor Client даёт 404, а curl работает
        let urlString = "https://api.telegram.org/bot\(botToken)/getChatMember"
        guard let url = URL(string: urlString) else {
            throw Abort(.badRequest, reason: "Invalid URL for getChatMember")
        }

        struct GetChatMemberPayload: Codable {
            let chat_id: String
            let user_id: Int64
        }

        let payload = GetChatMemberPayload(chat_id: String(finalChatId), user_id: userId)
        
        logger.info("getChatMember request: chat_id=\(finalChatId), user_id=\(userId)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payloadData = try JSONEncoder().encode(payload)
        request.httpBody = payloadData

        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw Abort(.badRequest, reason: "Invalid HTTP response")
        }
        
        guard httpResponse.statusCode == 200 else {
            if let errorString = String(data: data, encoding: .utf8) {
                logger.warning("getChatMember failed for chat_id=\(finalChatId) (username=@\(channelUsername)), status: \(httpResponse.statusCode), response: \(errorString)")
            } else {
                logger.warning("getChatMember failed for chat_id=\(finalChatId) (username=@\(channelUsername)), status: \(httpResponse.statusCode)")
            }
            throw Abort(.badRequest, reason: "getChatMember HTTP status \(httpResponse.statusCode)")
        }

        struct ChatMemberResponse: Decodable {
            struct Result: Decodable {
                let status: String
            }

            let ok: Bool
            let result: Result?
        }

        let decoded = try JSONDecoder().decode(ChatMemberResponse.self, from: data)

        guard decoded.ok, let result = decoded.result else {
            if let errorString = String(data: data, encoding: .utf8) {
                logger.warning("getChatMember returned not ok for chat_id=\(finalChatId) (username=@\(channelUsername)), response: \(errorString)")
            } else {
                logger.warning("getChatMember returned not ok for chat_id=\(finalChatId) (username=@\(channelUsername))")
            }
            throw Abort(.badRequest, reason: "getChatMember returned not ok for chat_id=\(finalChatId)")
        }

        let status = result.status
        // Подписан, если участник/админ/создатель
        return status == "member" || status == "administrator" || status == "creator"
    }
}

