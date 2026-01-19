import Foundation
import Vapor
#if canImport(SQLite3)
import SQLite3

typealias sqlite3_destructor_type = @convention(c) (UnsafeMutableRawPointer?) -> Void
let SQLITE_STATIC: sqlite3_destructor_type? = unsafeBitCast(0, to: sqlite3_destructor_type?.self)
let SQLITE_TRANSIENT: sqlite3_destructor_type? = unsafeBitCast(-1, to: sqlite3_destructor_type?.self)

#elseif canImport(CSQLite)
import CSQLite
// На Linux через CSQLite функции доступны, но нужно использовать их через правильный namespace
// Используем функции напрямую из libsqlite3
@_silgen_name("sqlite3_open")
func sqlite3_open(_ filename: UnsafePointer<CChar>, _ ppDb: UnsafeMutablePointer<OpaquePointer?>) -> Int32

@_silgen_name("sqlite3_close")
func sqlite3_close(_ db: OpaquePointer?) -> Int32

@_silgen_name("sqlite3_errmsg")
func sqlite3_errmsg(_ db: OpaquePointer?) -> UnsafePointer<CChar>?

@_silgen_name("sqlite3_exec")
func sqlite3_exec(_ db: OpaquePointer?, _ sql: UnsafePointer<CChar>?, _ callback: (@convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32)?, _ arg: UnsafeMutableRawPointer?, _ errmsg: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32

@_silgen_name("sqlite3_prepare_v2")
func sqlite3_prepare_v2(_ db: OpaquePointer?, _ zSql: UnsafePointer<CChar>?, _ nByte: Int32, _ ppStmt: UnsafeMutablePointer<OpaquePointer?>?, _ pzTail: UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32

@_silgen_name("sqlite3_finalize")
func sqlite3_finalize(_ pStmt: OpaquePointer?) -> Int32

@_silgen_name("sqlite3_bind_text")
func sqlite3_bind_text(_ pStmt: OpaquePointer?, _ i: Int32, _ zData: UnsafePointer<CChar>?, _ nData: Int32, _ xDel: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?) -> Int32

@_silgen_name("sqlite3_bind_int")
func sqlite3_bind_int(_ pStmt: OpaquePointer?, _ i: Int32, _ value: Int32) -> Int32

@_silgen_name("sqlite3_bind_int64")
func sqlite3_bind_int64(_ pStmt: OpaquePointer?, _ i: Int32, _ value: Int64) -> Int32

@_silgen_name("sqlite3_bind_null")
func sqlite3_bind_null(_ pStmt: OpaquePointer?, _ i: Int32) -> Int32

@_silgen_name("sqlite3_step")
func sqlite3_step(_ pStmt: OpaquePointer?) -> Int32

@_silgen_name("sqlite3_column_text")
func sqlite3_column_text(_ pStmt: OpaquePointer?, _ iCol: Int32) -> UnsafePointer<CChar>?

@_silgen_name("sqlite3_column_int")
func sqlite3_column_int(_ pStmt: OpaquePointer?, _ iCol: Int32) -> Int32

let SQLITE_OK: Int32 = 0
let SQLITE_DONE: Int32 = 101
let SQLITE_ROW: Int32 = 100
let SQLITE_NULL: Int32 = 5

@_silgen_name("sqlite3_reset")
func sqlite3_reset(_ pStmt: OpaquePointer?) -> Int32

@_silgen_name("sqlite3_column_type")
func sqlite3_column_type(_ pStmt: OpaquePointer?, _ iCol: Int32) -> Int32

typealias sqlite3_destructor_type = @convention(c) (UnsafeMutableRawPointer?) -> Void
let SQLITE_STATIC: sqlite3_destructor_type? = unsafeBitCast(0, to: sqlite3_destructor_type?.self)
let SQLITE_TRANSIENT: sqlite3_destructor_type? = unsafeBitCast(-1, to: sqlite3_destructor_type?.self)
#endif

/// Сервис монетизации для nowmttbot.
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
            app.logger.error("Failed to create directory for monetization DB (nowmttbot): \(error.localizedDescription)")
        }

        var db: OpaquePointer?
        let result = path.withCString { cPath in
            sqlite3_open(cPath, &db)
        }
        if result != SQLITE_OK {
            if let errorMessage = sqlite3_errmsg(db).flatMap({ String(cString: $0) }) {
                app.logger.error("Failed to open monetization DB at \(path) (nowmttbot): \(errorMessage)")
            } else {
                app.logger.error("Failed to open monetization DB at \(path) (nowmttbot)")
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
            require_subscription INTEGER NOT NULL DEFAULT 0,
            require_all_channels INTEGER NOT NULL DEFAULT 1
        );
        """

        for sql in [createUserSessionsSQL, createSponsorCampaignsSQL, createBotSettingsSQL] {
            let execResult = sql.withCString { cSql in
                sqlite3_exec(db, cSql, nil, nil, nil)
            }
            if execResult != SQLITE_OK {
                if let errorMessage = sqlite3_errmsg(db).flatMap({ String(cString: $0) }) {
                    app.logger.error("Failed to run schema SQL (nowmttbot): \(errorMessage)")
                } else {
                    app.logger.error("Failed to run schema SQL (nowmttbot, unknown error)")
                }
            }
        }
        
        // Миграция: добавляем поле require_all_channels если его нет
        let migrationSQL = """
        ALTER TABLE bot_settings ADD COLUMN require_all_channels INTEGER NOT NULL DEFAULT 1;
        """
        // Игнорируем ошибку если колонка уже существует
        migrationSQL.withCString { cSql in
            sqlite3_exec(db, cSql, nil, nil, nil)
        }

        app.logger.info("Monetization DB ensured at path (nowmttbot): \(path)")
    }

    /// Регистрирует/обновляет пользователя в user_sessions.
    static func registerUser(botName: String, chatId: Int64, logger: Logger, env: Environment) {
        let path = databasePath(env: env)
        var db: OpaquePointer?

        let openResult = path.withCString { cPath in
            sqlite3_open(cPath, &db)
        }
        guard openResult == SQLITE_OK else {
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
        let prepareResult = sql.withCString { cSql in
            sqlite3_prepare_v2(db, cSql, -1, &stmt, nil)
        }
        if prepareResult != SQLITE_OK {
            logger.error("Failed to prepare registerUser statement")
            return
        }
        defer { sqlite3_finalize(stmt) }

        let now = Int(Date().timeIntervalSince1970)
        botName.withCString { cBotName in
            sqlite3_bind_text(stmt, 1, cBotName, -1, SQLITE_TRANSIENT)
        }
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

        let openResult = path.withCString { cPath in
            sqlite3_open(cPath, &db)
        }
        guard openResult == SQLITE_OK else {
            logger.error("Failed to open monetization DB for checkAccess")
            if db != nil { sqlite3_close(db) }
            // Фейлим мягко: разрешаем доступ
            return (true, [])
        }
        defer { sqlite3_close(db) }

        // 1. Смотрим, включена ли вообще обязательная подписка для этого бота и требуется ли подписка на все каналы
        let settingSQL = """
        SELECT require_subscription, COALESCE(require_all_channels, 1) as require_all_channels
        FROM bot_settings
        WHERE bot_name = ?1;
        """

        var settingStmt: OpaquePointer?
        let prepareResult = settingSQL.withCString { cSql in
            sqlite3_prepare_v2(db, cSql, -1, &settingStmt, nil)
        }
        if prepareResult != SQLITE_OK {
            logger.error("Failed to prepare bot_settings in checkAccess")
            return (true, [])
        }
        defer { sqlite3_finalize(settingStmt) }

        botName.withCString { cBotName in
            sqlite3_bind_text(settingStmt, 1, cBotName, -1, SQLITE_TRANSIENT)
        }

        var requireSubscription = false
        var requireAllChannels = true // По умолчанию требуем подписку на все каналы
        if sqlite3_step(settingStmt) == SQLITE_ROW {
            requireSubscription = sqlite3_column_int(settingStmt, 0) != 0
            requireAllChannels = sqlite3_column_int(settingStmt, 1) != 0
        }

        logger.info("checkAccess for \(botName): require_subscription = \(requireSubscription), require_all_channels = \(requireAllChannels)")

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
        let campaignsPrepareResult = campaignsSQL.withCString { cSql in
            sqlite3_prepare_v2(db, cSql, -1, &campaignsStmt, nil)
        }
        if campaignsPrepareResult != SQLITE_OK {
            logger.error("Failed to prepare sponsor_campaigns in checkAccess")
            return (true, [])
        }
        defer { sqlite3_finalize(campaignsStmt) }

        botName.withCString { cBotName in
            sqlite3_bind_text(campaignsStmt, 1, cBotName, -1, SQLITE_TRANSIENT)
        }
        sqlite3_bind_int(campaignsStmt, 2, Int32(now))

        var campaigns: [Campaign] = []
        while sqlite3_step(campaignsStmt) == SQLITE_ROW {
            let username = String(cString: sqlite3_column_text(campaignsStmt, 0)!)
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

        if requireAllChannels {
            // Стратегия: требуется подписка на ВСЕ каналы
            var allSubscribed = true
            var checkedChannels = 0
            var accessibleChannels = 0
            
            for channel in channels {
                do {
                    let isMember = try await isUserMember(
                        userId: userId,
                        channelUsername: channel,
                        botToken: checkerToken,
                        client: client,
                        logger: logger
                    )
                    checkedChannels += 1
                    logger.info("checkAccess for \(botName): пользователь \(userId) на канале @\(channel): \(isMember ? "подписан" : "не подписан")")
                    if !isMember {
                        allSubscribed = false
                    }
                } catch {
                    // Ошибка при проверке одного канала - логируем, но продолжаем проверку других
                    accessibleChannels += 1
                    logger.warning("checkAccess for \(botName): ошибка при проверке канала @\(channel): \(error.localizedDescription)")
                }
            }
            
            // Если все каналы недоступны для проверки (все вернули ошибку) - применяем fail-open
            if checkedChannels == 0 && accessibleChannels == channels.count {
                logger.error("checkAccess for \(botName): все каналы недоступны для проверки, применяем fail-open стратегию")
                logger.warning("checkAccess for \(botName): из-за ошибки применяем fail-open стратегию, доступ разрешён")
                return (true, [])
            }
            
            // Если хотя бы один канал был проверен успешно
            if checkedChannels > 0 {
                if allSubscribed {
                    logger.info("checkAccess for \(botName): пользователь \(userId) подписан на все доступные каналы (\(checkedChannels) из \(channels.count)), доступ разрешён")
                    return (true, channels)
                } else {
                    logger.info("checkAccess for \(botName): пользователь \(userId) не подписан на все каналы (\(checkedChannels) из \(channels.count) проверено), доступ запрещён")
                    return (false, channels)
                }
            }
            
            // Если часть каналов недоступна, но ни на один доступный не подписан - запрещаем доступ
            logger.info("checkAccess for \(botName): пользователь \(userId) не подписан на все каналы (\(checkedChannels) из \(channels.count) проверено, \(accessibleChannels) недоступно), доступ запрещён")
            return (false, channels)
        } else {
            // Стратегия: достаточно быть подписанным хотя бы на один из каналов
                var checkedChannels = 0
                var accessibleChannels = 0
                
                for channel in channels {
                    do {
                        let isMember = try await isUserMember(
                            userId: userId,
                            channelUsername: channel,
                            botToken: checkerToken,
                            client: client,
                            logger: logger
                        )
                        checkedChannels += 1
                        logger.info("checkAccess for \(botName): пользователь \(userId) на канале @\(channel): \(isMember ? "подписан" : "не подписан")")
                        if isMember {
                            logger.info("checkAccess for \(botName): пользователь \(userId) подписан хотя бы на один канал, доступ разрешён")
                            return (true, channels)
                        }
                    } catch {
                        // Ошибка при проверке одного канала - логируем, но продолжаем проверку других
                        accessibleChannels += 1
                        logger.warning("checkAccess for \(botName): ошибка при проверке канала @\(channel): \(error.localizedDescription)")
                    }
                }
                
                // Если все каналы недоступны для проверки (все вернули ошибку) - применяем fail-open
                if checkedChannels == 0 && accessibleChannels == channels.count {
                    logger.error("checkAccess for \(botName): все каналы недоступны для проверки, применяем fail-open стратегию")
                    logger.warning("checkAccess for \(botName): из-за ошибки применяем fail-open стратегию, доступ разрешён")
                    return (true, [])
                }
                
                // Если хотя бы один канал был проверен успешно, но пользователь не подписан - запрещаем доступ
                if checkedChannels > 0 {
                    logger.info("checkAccess for \(botName): пользователь \(userId) не подписан ни на один из доступных каналов (\(checkedChannels) из \(channels.count) проверено), доступ запрещён")
                    return (false, channels)
                }
                
                // Если часть каналов недоступна, но ни на один доступный не подписан - запрещаем доступ
                logger.info("checkAccess for \(botName): пользователь \(userId) не подписан ни на один из каналов (\(checkedChannels) из \(channels.count) проверено, \(accessibleChannels) недоступно), доступ запрещён")
                return (false, channels)
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
        let urlString = "https://api.telegram.org/bot\(botToken)/getChatMember"

        struct GetChatMemberPayload: Codable {
            let chat_id: String
            let user_id: Int64
        }

        let payload = GetChatMemberPayload(chat_id: String(finalChatId), user_id: userId)
        
        logger.info("getChatMember request: chat_id=\(finalChatId), user_id=\(userId)")

        let response = try await client.post(URI(string: urlString)) { req in
            try req.content.encode(payload, as: .json)
        }
        
        guard response.status == .ok else {
            let bodyString = response.body.map { String(buffer: $0) } ?? "no body"
            logger.warning("getChatMember failed for chat_id=\(finalChatId) (username=@\(channelUsername)), status: \(response.status.code), response: \(bodyString)")
            throw Abort(.badRequest, reason: "getChatMember HTTP status \(response.status.code)")
        }

        struct ChatMemberResponse: Decodable {
            struct Result: Decodable {
                let status: String
            }

            let ok: Bool
            let result: Result?
        }

        let decoded = try response.content.decode(ChatMemberResponse.self)

        guard decoded.ok, let result = decoded.result else {
            let bodyString = response.body.map { String(buffer: $0) } ?? "no body"
            logger.warning("getChatMember returned not ok for chat_id=\(finalChatId) (username=@\(channelUsername)), response: \(bodyString)")
            throw Abort(.badRequest, reason: "getChatMember returned not ok for chat_id=\(finalChatId)")
        }

        let status = result.status
        // Подписан, если участник/админ/создатель
        return status == "member" || status == "administrator" || status == "creator"
    }
}

