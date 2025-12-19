import Foundation
import Vapor
import SQLite3

/// Небольшой сервис для работы с базой монетизации (SQLite).
/// Используем минимальный набор функций и простой SQL без Fluent.
enum MonetizationDatabase {
    // MARK: - Paths / Env

    static func databasePath(env: Environment) -> String {
        // Позволяем переопределить путь через MONETIZATION_DB_PATH
        if let fromEnv = Environment.get("MONETIZATION_DB_PATH"), fromEnv.isEmpty == false {
            return fromEnv
        }
        // По умолчанию кладём файл в config/monetization.sqlite
        return "config/monetization.sqlite"
    }

    // MARK: - Public API

    /// Гарантирует, что файл базы существует и созданы необходимые таблицы.
    static func ensureDatabase(app: Application) {
        let path = databasePath(env: app.environment)
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
        } catch {
            app.logger.error("Failed to create directory for monetization DB: \(error.localizedDescription)")
        }

        var db: OpaquePointer?
        if sqlite3_open(path, &db) != SQLITE_OK {
            if let errorMessage = sqlite3_errmsg(db).flatMap({ String(cString: $0) }) {
                app.logger.error("Failed to open monetization DB at \(path): \(errorMessage)")
            } else {
                app.logger.error("Failed to open monetization DB at \(path)")
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
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                if let errorMessage = sqlite3_errmsg(db).flatMap({ String(cString: $0) }) {
                    app.logger.error("Failed to run schema SQL: \(errorMessage)")
                } else {
                    app.logger.error("Failed to run schema SQL (unknown error)")
                }
                // Не кидаем ошибку наружу: база монетизации не должна ломать сервис
            }
        }
        
        // Миграция: добавляем поле require_all_channels если его нет
        let migrationSQL = """
        ALTER TABLE bot_settings ADD COLUMN require_all_channels INTEGER NOT NULL DEFAULT 1;
        """
        // Игнорируем ошибку если колонка уже существует
        sqlite3_exec(db, migrationSQL, nil, nil, nil)

        // Инициализируем записи для всех ботов из NOWCONTROLLERBOT_BROADCAST_BOTS
        // Это гарантирует, что настройки явно видны в БД (require_subscription = 0 по умолчанию)
        if let managedBotsEnv = Environment.get("NOWCONTROLLERBOT_BROADCAST_BOTS"), !managedBotsEnv.isEmpty {
            let managedBots = managedBotsEnv
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            
            let initSettingsSQL = """
            INSERT OR IGNORE INTO bot_settings (bot_name, require_subscription, require_all_channels)
            VALUES (?1, 0, 1);
            """
            
            var initStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, initSettingsSQL, -1, &initStmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(initStmt) }
                
                for botName in managedBots {
                    sqlite3_reset(initStmt)
                    sqlite3_bind_text(initStmt, 1, (botName as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    
                    if sqlite3_step(initStmt) == SQLITE_DONE {
                        app.logger.info("Initialized bot_settings for \(botName) with require_subscription=0")
                    } else {
                        if let errorMessage = sqlite3_errmsg(db).flatMap({ String(cString: $0) }) {
                            app.logger.warning("Failed to initialize bot_settings for \(botName): \(errorMessage)")
                        }
                    }
                }
            } else {
                if let errorMessage = sqlite3_errmsg(db).flatMap({ String(cString: $0) }) {
                    app.logger.warning("Failed to prepare bot_settings init statement: \(errorMessage)")
                }
            }
        } else {
            app.logger.info("NOWCONTROLLERBOT_BROADCAST_BOTS not set, skipping bot_settings initialization")
        }

        app.logger.info("Monetization DB ensured at path: \(path)")
    }

    // MARK: - Helpers for NowControllerBot

    struct SponsorCampaign {
        let id: Int
        let botName: String
        let channelUsername: String
        let active: Bool
        let expiresAt: Int?
        let createdAt: Int
    }

    struct BotSetting {
        let botName: String
        let requireSubscription: Bool
        let requireAllChannels: Bool
    }

    /// Возвращает список активных и неистёкших кампаний для указанного бота.
    static func activeCampaigns(for botName: String, logger: Logger, env: Environment) -> [SponsorCampaign] {
        let path = databasePath(env: env)
        var db: OpaquePointer?
        var campaigns: [SponsorCampaign] = []

        guard sqlite3_open(path, &db) == SQLITE_OK else {
            logger.error("Failed to open monetization DB for reading campaigns")
            if db != nil { sqlite3_close(db) }
            return campaigns
        }
        defer { sqlite3_close(db) }

        let now = Int(Date().timeIntervalSince1970)
        let sql = """
        SELECT id, bot_name, channel_username, active, expires_at, created_at
        FROM sponsor_campaigns
        WHERE bot_name = ?1
          AND active = 1
          AND (expires_at IS NULL OR expires_at >= ?2)
        ORDER BY created_at ASC;
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            logger.error("Failed to prepare campaigns query")
            return campaigns
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (botName as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(now))

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int(stmt, 0))
            let botNameValue = String(cString: sqlite3_column_text(stmt, 1))
            let channelUsername = String(cString: sqlite3_column_text(stmt, 2))
            let activeValue = sqlite3_column_int(stmt, 3) != 0
            let expiresValue = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 4))
            let createdAt = Int(sqlite3_column_int(stmt, 5))

            campaigns.append(SponsorCampaign(
                id: id,
                botName: botNameValue,
                channelUsername: channelUsername,
                active: activeValue,
                expiresAt: expiresValue,
                createdAt: createdAt
            ))
        }

        return campaigns
    }

    /// Возвращает настройку require_subscription для бота (если есть).
    static func botSetting(for botName: String, logger: Logger, env: Environment) -> BotSetting? {
        let path = databasePath(env: env)
        var db: OpaquePointer?

        guard sqlite3_open(path, &db) == SQLITE_OK else {
            logger.error("Failed to open monetization DB for reading bot_settings")
            if db != nil { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT bot_name, require_subscription, COALESCE(require_all_channels, 1) as require_all_channels
        FROM bot_settings
        WHERE bot_name = ?1;
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            logger.error("Failed to prepare bot_settings query")
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (botName as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        if sqlite3_step(stmt) == SQLITE_ROW {
            let nameValue = String(cString: sqlite3_column_text(stmt, 0))
            let requireValue = sqlite3_column_int(stmt, 1) != 0
            let requireAllChannelsValue = sqlite3_column_int(stmt, 2) != 0
            return BotSetting(botName: nameValue, requireSubscription: requireValue, requireAllChannels: requireAllChannelsValue)
        }

        return nil
    }

    /// Устанавливает флаг require_subscription для бота.
    static func setRequireSubscription(
        botName: String,
        require: Bool,
        logger: Logger,
        env: Environment
    ) {
        let path = databasePath(env: env)
        var db: OpaquePointer?

        guard sqlite3_open(path, &db) == SQLITE_OK else {
            logger.error("Failed to open monetization DB for updating bot_settings")
            if db != nil { sqlite3_close(db) }
            return
        }
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO bot_settings (bot_name, require_subscription)
        VALUES (?1, ?2)
        ON CONFLICT(bot_name) DO UPDATE SET require_subscription = excluded.require_subscription;
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            logger.error("Failed to prepare bot_settings upsert")
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (botName as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, require ? 1 : 0)

        if sqlite3_step(stmt) != SQLITE_DONE {
            logger.error("Failed to execute bot_settings upsert")
        }
    }

    /// Добавляет кампанию спонсора.
    static func addSponsorCampaign(
        botName: String,
        channelUsername: String,
        expiresAt: Int?,
        logger: Logger,
        env: Environment
    ) {
        let path = databasePath(env: env)
        var db: OpaquePointer?

        guard sqlite3_open(path, &db) == SQLITE_OK else {
            logger.error("Failed to open monetization DB for inserting sponsor_campaign")
            if db != nil { sqlite3_close(db) }
            return
        }
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO sponsor_campaigns (bot_name, channel_username, active, expires_at, created_at)
        VALUES (?1, ?2, 1, ?3, ?4);
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            logger.error("Failed to prepare sponsor_campaign insert")
            return
        }
        defer { sqlite3_finalize(stmt) }

        let now = Int(Date().timeIntervalSince1970)

        sqlite3_bind_text(stmt, 1, (botName as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, (channelUsername as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        if let expires = expiresAt {
            sqlite3_bind_int(stmt, 3, Int32(expires))
        } else {
            sqlite3_bind_null(stmt, 3)
        }

        sqlite3_bind_int(stmt, 4, Int32(now))

        if sqlite3_step(stmt) != SQLITE_DONE {
            logger.error("Failed to insert sponsor_campaign")
        }
    }

    /// Деактивирует кампанию по id.
    static func deactivateCampaign(id: Int, logger: Logger, env: Environment) {
        let path = databasePath(env: env)
        var db: OpaquePointer?

        guard sqlite3_open(path, &db) == SQLITE_OK else {
            logger.error("Failed to open monetization DB for deactivating campaign")
            if db != nil { sqlite3_close(db) }
            return
        }
        defer { sqlite3_close(db) }

        let sql = "UPDATE sponsor_campaigns SET active = 0 WHERE id = ?1;"

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            logger.error("Failed to prepare deactivate campaign")
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(id))

        if sqlite3_step(stmt) != SQLITE_DONE {
            logger.error("Failed to execute deactivate campaign")
        }
    }

    /// Возвращает краткую статистику по пользователям (по bot_name и количеству chat_id).
    static func userStats(logger: Logger, env: Environment) -> [String: Int] {
        let path = databasePath(env: env)
        var db: OpaquePointer?
        var result: [String: Int] = [:]

        guard sqlite3_open(path, &db) == SQLITE_OK else {
            logger.error("Failed to open monetization DB for user stats")
            if db != nil { sqlite3_close(db) }
            return result
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT bot_name, COUNT(*) as cnt
        FROM user_sessions
        GROUP BY bot_name;
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            logger.error("Failed to prepare user stats query")
            return result
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let nameValue = String(cString: sqlite3_column_text(stmt, 0))
            let countValue = Int(sqlite3_column_int(stmt, 1))
            result[nameValue] = countValue
        }

        return result
    }

    /// Возвращает количество активных спонсоров для указанного бота.
    static func sponsorCount(for botName: String, logger: Logger, env: Environment) -> Int {
        let path = databasePath(env: env)
        var db: OpaquePointer?
        
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            logger.error("Failed to open monetization DB for sponsor count")
            if db != nil { sqlite3_close(db) }
            return 0
        }
        defer { sqlite3_close(db) }
        
        let now = Int(Date().timeIntervalSince1970)
        let sql = """
        SELECT COUNT(*) 
        FROM sponsor_campaigns
        WHERE bot_name = ?1
          AND active = 1
          AND (expires_at IS NULL OR expires_at >= ?2);
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            logger.error("Failed to prepare sponsor count query")
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (botName as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(stmt, 2, Int32(now))
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        
        return 0
    }
    
    /// Возвращает список уникальных ботов, у которых есть активные спонсорские кампании.
    static func botsWithActiveSponsors(logger: Logger, env: Environment) -> [String] {
        let path = databasePath(env: env)
        var db: OpaquePointer?
        var bots: [String] = []

        guard sqlite3_open(path, &db) == SQLITE_OK else {
            logger.error("Failed to open monetization DB for bots with sponsors")
            if db != nil { sqlite3_close(db) }
            return bots
        }
        defer { sqlite3_close(db) }

        let now = Int(Date().timeIntervalSince1970)
        let sql = """
        SELECT DISTINCT bot_name
        FROM sponsor_campaigns
        WHERE active = 1
          AND (expires_at IS NULL OR expires_at >= ?1)
        ORDER BY bot_name ASC;
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            logger.error("Failed to prepare bots with sponsors query")
            return bots
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(now))

        while sqlite3_step(stmt) == SQLITE_ROW {
            let botName = String(cString: sqlite3_column_text(stmt, 0))
            bots.append(botName)
        }

        return bots
    }
}


