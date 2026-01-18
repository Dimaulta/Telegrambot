import Vapor
import Foundation

// MARK: - Admin session state for пошаговые сценарии

private actor AdminSessionStore {
    static let shared = AdminSessionStore()

    enum Step {
        case idle
        case addSponsorChooseBot
        case addSponsorWaitChannel(botName: String)
        case addSponsorWaitDuration(botName: String, channel: String)
        case deleteSponsorChooseBot
        case deleteSponsorChooseChannel(botName: String)
    }

    private var states: [Int64: Step] = [:]

    func state(for chatId: Int64) -> Step {
        return states[chatId] ?? .idle
    }

    func setState(_ step: Step, for chatId: Int64) {
        states[chatId] = step
    }

    func reset(chatId: Int64) {
        states[chatId] = .idle
    }
}

// Отслеживание обработанных сообщений для предотвращения дублирования
private actor ProcessedMessagesStore {
    static let shared = ProcessedMessagesStore()
    
    // Храним последние 1000 обработанных сообщений (chatId:messageId)
    private var processedMessages: Set<String> = []
    private let maxSize = 1000
    
    func isProcessed(chatId: Int64, messageId: Int) -> Bool {
        let key = "\(chatId):\(messageId)"
        return processedMessages.contains(key)
    }
    
    func markAsProcessed(chatId: Int64, messageId: Int) {
        let key = "\(chatId):\(messageId)"
        processedMessages.insert(key)
        
        // Если превысили лимит - удаляем самые старые (просто очищаем половину)
        if processedMessages.count > maxSize {
            let toRemove = processedMessages.prefix(maxSize / 2)
            for item in toRemove {
                processedMessages.remove(item)
            }
        }
    }
}

final class NowControllerBotController {
    // MARK: - Bot name mapping для коротких названий на кнопках
    private static let botDisplayNames: [String: String] = [
        "nowmttbot": "Тикток",
        "gsfortextbot": "Голос",
        "roundsvideobot": "Кружочек",
        "neurfotobot": "Нейрофото",
        "contentfabrikabot": "Посты",
        "pereskaznowbot": "Пересказ"
    ]
    
    private static func displayName(for botName: String) -> String {
        return botDisplayNames[botName.lowercased()] ?? botName
    }
    
    private static func botName(from displayName: String) -> String? {
        // Ищем системное имя по короткому названию
        for (systemName, display) in botDisplayNames {
            if display.lowercased() == displayName.lowercased() {
                return systemName
            }
        }
        // Если не нашли - возможно это уже системное имя
        return displayName
    }
    
    // MARK: - Entry point

    func handleWebhook(_ req: Request) async throws -> Response {
        req.logger.info("🔔 NowControllerBot webhook hit!")
        req.logger.info("Method: \(req.method), Path: \(req.url.path)")

        guard let botToken = Environment.get("NOWCONTROLLERBOT_TOKEN"), botToken.isEmpty == false else {
            req.logger.error("NOWCONTROLLERBOT_TOKEN is missing")
            return Response(status: .internalServerError)
        }

        let rawBody = req.body.string ?? ""
        req.logger.info("📦 Raw body length: \(rawBody.count) characters")
        if rawBody.count > 0 && rawBody.count < 1000 {
            req.logger.debug("Raw body: \(rawBody)")
        }

        req.logger.info("🔍 Decoding NowControllerBotUpdate...")
        let update = try? req.content.decode(NowControllerBotUpdate.self)
        guard let safeUpdate = update else {
            req.logger.error("❌ Failed to decode NowControllerBotUpdate - check raw body above")
            return Response(status: .ok)
        }
        req.logger.info("✅ NowControllerBotUpdate decoded successfully")

        guard let message = safeUpdate.message else {
            req.logger.warning("⚠️ No message in update (update_id: \(safeUpdate.update_id))")
            return Response(status: .ok)
        }

        let text = message.text ?? ""
        let chatId = message.chat.id
        let messageId = message.message_id

        // Проверяем, не обрабатывали ли мы уже это сообщение
        let isAlreadyProcessed = await ProcessedMessagesStore.shared.isProcessed(chatId: chatId, messageId: messageId)
        if isAlreadyProcessed {
            req.logger.info("⚠️ Message \(messageId) from chat \(chatId) already processed, skipping duplicate")
            return Response(status: .ok)
        }
        
        // Помечаем сообщение как обработанное
        await ProcessedMessagesStore.shared.markAsProcessed(chatId: chatId, messageId: messageId)

        req.logger.info("📨 Incoming message - chatId=\(chatId), messageId=\(messageId), text length=\(text.count)")
        if !text.isEmpty {
            req.logger.info("📝 Message text: \(text.prefix(200))")
        }

        // Проверяем, что это админ
        guard isAdmin(chatId: chatId) else {
            req.logger.info("Non-admin user tried to use NowControllerBot: chatId=\(chatId)")
            // Можем молча игнорировать или отправить вежливое сообщение
            _ = try? await sendTelegramMessage(
                token: botToken,
                chatId: chatId,
                text: "Этот бот предназначен только для администратора.",
                client: req.client
            )
            return Response(status: .ok)
        }

        // Текущее состояние пошагового сценария
        let currentStep = await AdminSessionStore.shared.state(for: chatId)

        // Обработка /start: сбрасываем состояние и показываем главное меню
        if text.hasPrefix("/start") {
            await AdminSessionStore.shared.reset(chatId: chatId)

            let help = """
            Привет! Это NowControllerBot для управления монетизацией @NowBots

            📱 Твой Telegram ID: \(chatId)
            (Добавь его на свой VPS в .env как NOWCONTROLLERBOT_ADMIN_ID=<твой_телеграм_id> и перезапусти сервис)

            Я помогу:
            • Смотреть статус по ботам
            • Включать/выключать обязательную подписку
            • Управлять спонсорами для всех ботов

            📋 Команды:
            /status – краткий статус по пользователям и спонсорам
            /set_require <bot> <on|off> – включить/выключить обязательную подписку
            /add_sponsor <bot> <@канал|ссылка> <days|0> – добавить спонсора (0 = без срока)
            /list_sponsors <bot> – показать активных спонсоров для бота
            /delete_sponsor <bot> <@канал> – удалить спонсора для бота
            """

            let keyboard = buildMainKeyboard(logger: req.logger, env: req.application.environment)

            _ = try? await sendTelegramMessage(
                token: botToken,
                chatId: chatId,
                text: help,
                client: req.client,
                replyMarkup: keyboard
            )
            return Response(status: .ok)
        }

        // Обработка кнопки "➕ Спонсор" - показываем меню
        if text == "➕ Спонсор" {
            let managedBotsEnv = Environment.get("NOWCONTROLLERBOT_BROADCAST_BOTS") ?? ""
            let managedBots = managedBotsEnv
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            if managedBots.isEmpty {
                let reply = "NOWCONTROLLERBOT_BROADCAST_BOTS не задан — список управляемых ботов пуст."
                _ = try? await sendTelegramMessage(token: botToken, chatId: chatId, text: reply, client: req.client)
                return Response(status: .ok)
            }

            let keyboard = ReplyKeyboardMarkup(
                keyboard: [
                    [KeyboardButton(text: "➕ Добавить спонсора"), KeyboardButton(text: "🗑 Удалить спонсора")],
                    [KeyboardButton(text: "📊 Статус")]
                ],
                resize_keyboard: true,
                one_time_keyboard: false
            )

            let reply = "Выбери действие со спонсорами:"
            _ = try? await sendTelegramMessage(
                token: botToken,
                chatId: chatId,
                text: reply,
                client: req.client,
                replyMarkup: keyboard
            )
            return Response(status: .ok)
        }

        // Обработка шагов сценария добавления спонсора
        if text == "➕ Добавить спонсора" {
            await AdminSessionStore.shared.setState(.addSponsorChooseBot, for: chatId)

            let managedBotsEnv = Environment.get("NOWCONTROLLERBOT_BROADCAST_BOTS") ?? ""
            let managedBots = managedBotsEnv
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            if managedBots.isEmpty {
                let reply = "NOWCONTROLLERBOT_BROADCAST_BOTS не задан — список управляемых ботов пуст. Добавление спонсора невозможно."
                _ = try? await sendTelegramMessage(token: botToken, chatId: chatId, text: reply, client: req.client)
                return Response(status: .ok)
            }

            let rows = managedBots.map { [KeyboardButton(text: String($0))] }
            let keyboard = ReplyKeyboardMarkup(
                keyboard: rows + [[KeyboardButton(text: "❌ Отмена")]],
                resize_keyboard: true,
                one_time_keyboard: false
            )

            let prompt = "Выбери бота, для которого нужно добавить спонсора."
            _ = try? await sendTelegramMessage(
                token: botToken,
                chatId: chatId,
                text: prompt,
                client: req.client,
                replyMarkup: keyboard
            )
            return Response(status: .ok)
        }

        // Если мы внутри сценария добавления спонсора — обрабатываем его шаги
        switch currentStep {
        case .addSponsorChooseBot:
            // Пользователь либо выбирает бота, либо отменяет
            if text == "❌ Отмена" {
                await AdminSessionStore.shared.reset(chatId: chatId)
                let reply = "Добавление спонсора отменено."
                _ = try? await sendTelegramMessage(token: botToken, chatId: chatId, text: reply, client: req.client)
                return Response(status: .ok)
            }

            let botName = text.trimmingCharacters(in: .whitespaces)
            if botName.isEmpty {
                let reply = "Выбери бота из списка или нажми «❌ Отмена»."
                _ = try? await sendTelegramMessage(token: botToken, chatId: chatId, text: reply, client: req.client)
                return Response(status: .ok)
            }

            // Переходим к следующему шагу — ждём канал
            await AdminSessionStore.shared.setState(.addSponsorWaitChannel(botName: botName), for: chatId)

            let keyboard = ReplyKeyboardMarkup(
                keyboard: [[KeyboardButton(text: "❌ Отмена")]],
                resize_keyboard: true,
                one_time_keyboard: false
            )
            let prompt = "Пришли @username или ссылку на канал спонсора для бота \(botName)."
            _ = try? await sendTelegramMessage(
                token: botToken,
                chatId: chatId,
                text: prompt,
                client: req.client,
                replyMarkup: keyboard
            )
            return Response(status: .ok)

        case .addSponsorWaitChannel(let botName):
            if text == "❌ Отмена" {
                await AdminSessionStore.shared.reset(chatId: chatId)
                let reply = "Добавление спонсора отменено."
                _ = try? await sendTelegramMessage(token: botToken, chatId: chatId, text: reply, client: req.client)
                return Response(status: .ok)
            }

            guard let normalized = normalizeChannelIdentifier(text) else {
                let reply = "Не удалось распознать канал из '\(text)'. Пришли @username или ссылку https://t.me/username, либо нажми «❌ Отмена»."
                _ = try? await sendTelegramMessage(token: botToken, chatId: chatId, text: reply, client: req.client)
                return Response(status: .ok)
            }

            await AdminSessionStore.shared.setState(.addSponsorWaitDuration(botName: botName, channel: normalized), for: chatId)

            let keyboard = ReplyKeyboardMarkup(
                keyboard: [
                    [KeyboardButton(text: "7 дней"), KeyboardButton(text: "30 дней")],
                    [KeyboardButton(text: "90 дней"), KeyboardButton(text: "Без срока")],
                    [KeyboardButton(text: "❌ Отмена")]
                ],
                resize_keyboard: true,
                one_time_keyboard: false
            )

            let prompt = "Выбери срок обязательной подписки для канала @\(normalized) (относительно бота \(botName))."
            _ = try? await sendTelegramMessage(
                token: botToken,
                chatId: chatId,
                text: prompt,
                client: req.client,
                replyMarkup: keyboard
            )
            return Response(status: .ok)

        case .addSponsorWaitDuration(let botName, let channel):
            if text == "❌ Отмена" {
                await AdminSessionStore.shared.reset(chatId: chatId)
                let reply = "Добавление спонсора отменено."
                _ = try? await sendTelegramMessage(token: botToken, chatId: chatId, text: reply, client: req.client)
                return Response(status: .ok)
            }

            let days: Int
            switch text {
            case "7 дней":
                days = 7
            case "30 дней":
                days = 30
            case "90 дней":
                days = 90
            case "Без срока":
                days = 0
            default:
                let reply = "Выбери один из вариантов: 7 дней, 30 дней, 90 дней или Без срока. Или нажми «❌ Отмена»."
                _ = try? await sendTelegramMessage(token: botToken, chatId: chatId, text: reply, client: req.client)
                return Response(status: .ok)
            }

            let synthetic = "/add_sponsor \(botName) @\(channel) \(days)"
            let reply = handleAddSponsorCommand(text: synthetic, logger: req.logger, env: req.application.environment)

            await AdminSessionStore.shared.reset(chatId: chatId)

            let keyboard = buildMainKeyboard(logger: req.logger, env: req.application.environment)

            _ = try? await sendTelegramMessage(
                token: botToken,
                chatId: chatId,
                text: reply,
                client: req.client,
                replyMarkup: keyboard
            )
            return Response(status: .ok)

        case .deleteSponsorChooseBot:
            if text == "❌ Отмена" {
                await AdminSessionStore.shared.reset(chatId: chatId)
                let reply = "Удаление спонсора отменено."
                _ = try? await sendTelegramMessage(token: botToken, chatId: chatId, text: reply, client: req.client)
                return Response(status: .ok)
            }

            let botName = text.trimmingCharacters(in: .whitespaces)
            if botName.isEmpty {
                let reply = "Выбери бота из списка или нажми «❌ Отмена»."
                _ = try? await sendTelegramMessage(token: botToken, chatId: chatId, text: reply, client: req.client)
                return Response(status: .ok)
            }

            let campaigns = MonetizationDatabase.activeCampaigns(for: botName, logger: req.logger, env: req.application.environment)
            if campaigns.isEmpty {
                await AdminSessionStore.shared.reset(chatId: chatId)
                let reply = "Для бота \(botName) нет активных спонсорских кампаний."
                _ = try? await sendTelegramMessage(token: botToken, chatId: chatId, text: reply, client: req.client)
                return Response(status: .ok)
            }

            await AdminSessionStore.shared.setState(.deleteSponsorChooseChannel(botName: botName), for: chatId)

            let channelRows = campaigns.map { campaign in
                [KeyboardButton(text: "@\(campaign.channelUsername)")]
            }
            let keyboard = ReplyKeyboardMarkup(
                keyboard: channelRows + [[KeyboardButton(text: "❌ Отмена")]],
                resize_keyboard: true,
                one_time_keyboard: false
            )

            let prompt = "Выбери канал спонсора для удаления у бота \(botName):"
            _ = try? await sendTelegramMessage(
                token: botToken,
                chatId: chatId,
                text: prompt,
                client: req.client,
                replyMarkup: keyboard
            )
            return Response(status: .ok)

        case .deleteSponsorChooseChannel(let botName):
            if text == "❌ Отмена" {
                await AdminSessionStore.shared.reset(chatId: chatId)
                let reply = "Удаление спонсора отменено."
                _ = try? await sendTelegramMessage(token: botToken, chatId: chatId, text: reply, client: req.client)
                return Response(status: .ok)
            }

            guard text.hasPrefix("@") else {
                let reply = "Выбери канал из списка (начинается с @) или нажми «❌ Отмена»."
                _ = try? await sendTelegramMessage(token: botToken, chatId: chatId, text: reply, client: req.client)
                return Response(status: .ok)
            }

            let channelUsername = String(text.dropFirst()) // Убираем @
            let campaigns = MonetizationDatabase.activeCampaigns(for: botName, logger: req.logger, env: req.application.environment)
            
            if let campaign = campaigns.first(where: { $0.channelUsername == channelUsername }) {
                MonetizationDatabase.deactivateCampaign(id: campaign.id, logger: req.logger, env: req.application.environment)
                
                // Проверяем, остались ли еще активные спонсоры у бота
                let remainingCampaigns = MonetizationDatabase.activeCampaigns(for: botName, logger: req.logger, env: req.application.environment)
                
                var reply = "Спонсор @\(channelUsername) удалён для бота \(botName)."
                
                // Если не осталось активных спонсоров - автоматически отключаем подписку
                if remainingCampaigns.isEmpty {
                    MonetizationDatabase.setRequireSubscription(
                        botName: botName,
                        require: false,
                        logger: req.logger,
                        env: req.application.environment
                    )
                    reply += "\n\n⚠️ У бота не осталось активных спонсоров. Обязательная подписка автоматически отключена."
                }
                
                await AdminSessionStore.shared.reset(chatId: chatId)
                let keyboard = buildMainKeyboard(logger: req.logger, env: req.application.environment)
                _ = try? await sendTelegramMessage(
                    token: botToken,
                    chatId: chatId,
                    text: reply,
                    client: req.client,
                    replyMarkup: keyboard
                )
            } else {
                let reply = "Канал @\(channelUsername) не найден среди активных спонсоров для бота \(botName)."
                _ = try? await sendTelegramMessage(token: botToken, chatId: chatId, text: reply, client: req.client)
            }
            return Response(status: .ok)

        case .idle:
            break
        }

        // Кнопка "📊 Статус" обрабатывается как /status
        if text == "📊 Статус" || text.hasPrefix("/status") {
            let statusText = buildStatusText(logger: req.logger, env: req.application.environment)
            _ = try? await sendTelegramMessage(token: botToken, chatId: chatId, text: statusText, client: req.client)
            return Response(status: .ok)
        }

        // Обработка кнопки "🗑 Удалить спонсора"
        if text == "🗑 Удалить спонсора" {
            await AdminSessionStore.shared.setState(.deleteSponsorChooseBot, for: chatId)

            let botsWithSponsors = MonetizationDatabase.botsWithActiveSponsors(logger: req.logger, env: req.application.environment)
            
            if botsWithSponsors.isEmpty {
                await AdminSessionStore.shared.reset(chatId: chatId)
                let reply = "Нет ботов с активными спонсорскими кампаниями."
                _ = try? await sendTelegramMessage(token: botToken, chatId: chatId, text: reply, client: req.client)
                return Response(status: .ok)
            }

            let rows = botsWithSponsors.map { [KeyboardButton(text: $0)] }
            let keyboard = ReplyKeyboardMarkup(
                keyboard: rows + [[KeyboardButton(text: "❌ Отмена")]],
                resize_keyboard: true,
                one_time_keyboard: false
            )

            let prompt = "Выбери бота, у которого нужно удалить спонсора."
            _ = try? await sendTelegramMessage(
                token: botToken,
                chatId: chatId,
                text: prompt,
                client: req.client,
                replyMarkup: keyboard
            )
            return Response(status: .ok)
        }

        // Обработка динамических кнопок включения/выключения подписки для всех ботов
        // ✅ показывает статус "включено", нажатие выключает
        if text.hasPrefix("✅ ") {
            let displayName = String(text.dropFirst("✅ ".count))
            let botName = Self.botName(from: displayName) ?? displayName
            let synthetic = "/set_require \(botName) off"
            let reply = handleSetRequireCommand(text: synthetic, logger: req.logger, env: req.application.environment)
            let keyboard = buildMainKeyboard(logger: req.logger, env: req.application.environment)
            _ = try? await sendTelegramMessage(
                token: botToken,
                chatId: chatId,
                text: reply,
                client: req.client,
                replyMarkup: keyboard
            )
            return Response(status: .ok)
        }

        // ⛔️ показывает статус "выключено", нажатие включает
        if text.hasPrefix("⛔️ ") {
            let displayName = String(text.dropFirst("⛔️ ".count))
            let botName = Self.botName(from: displayName) ?? displayName
            let synthetic = "/set_require \(botName) on"
            let reply = handleSetRequireCommand(text: synthetic, logger: req.logger, env: req.application.environment)
            let keyboard = buildMainKeyboard(logger: req.logger, env: req.application.environment)
            _ = try? await sendTelegramMessage(
                token: botToken,
                chatId: chatId,
                text: reply,
                client: req.client,
                replyMarkup: keyboard
            )
            return Response(status: .ok)
        }

        if text.hasPrefix("/set_require") {
            let reply = handleSetRequireCommand(text: text, logger: req.logger, env: req.application.environment)
            _ = try? await sendTelegramMessage(token: botToken, chatId: chatId, text: reply, client: req.client)
            return Response(status: .ok)
        }

        if text.hasPrefix("/add_sponsor") {
            let reply = handleAddSponsorCommand(text: text, logger: req.logger, env: req.application.environment)
            _ = try? await sendTelegramMessage(token: botToken, chatId: chatId, text: reply, client: req.client)
            return Response(status: .ok)
        }

        if text.hasPrefix("/list_sponsors") {
            let reply = handleListSponsorsCommand(text: text, logger: req.logger, env: req.application.environment)
            _ = try? await sendTelegramMessage(token: botToken, chatId: chatId, text: reply, client: req.client)
            return Response(status: .ok)
        }

        if text.hasPrefix("/delete_sponsor") {
            let reply = handleDeleteSponsorCommand(text: text, logger: req.logger, env: req.application.environment)
            let keyboard = buildMainKeyboard(logger: req.logger, env: req.application.environment)
            _ = try? await sendTelegramMessage(
                token: botToken,
                chatId: chatId,
                text: reply,
                client: req.client,
                replyMarkup: keyboard
            )
            return Response(status: .ok)
        }

        // На любой другой текст показываем краткую подсказку
        let fallback = "Неизвестная команда. Используй /start, чтобы увидеть список доступных команд."
        _ = try? await sendTelegramMessage(token: botToken, chatId: chatId, text: fallback, client: req.client)

        return Response(status: .ok)
    }

    // MARK: - Admin check

    private func isAdmin(chatId: Int64) -> Bool {
        guard let raw = Environment.get("NOWCONTROLLERBOT_ADMIN_ID"), raw.isEmpty == false else {
            // Если переменная не задана, считаем, что админ не настроен и никому не даём доступ
            return false
        }
        if let expected = Int64(raw) {
            return chatId == expected
        }
        return false
    }

    // MARK: - Commands

    /// Синхронизирует состояние подписки для всех ботов:
    /// если у бота нет активных спонсоров, но подписка включена - отключает её.
    private func syncBotSubscriptionSettings(logger: Logger, env: Environment) {
        let managedBotsEnv = Environment.get("NOWCONTROLLERBOT_BROADCAST_BOTS") ?? ""
        let managedBots = managedBotsEnv
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        guard !managedBots.isEmpty else {
            return
        }
        
        for botName in managedBots {
            // Проверяем, есть ли активные спонсоры у бота
            let campaigns = MonetizationDatabase.activeCampaigns(for: botName, logger: logger, env: env)
            
            // Если нет активных спонсоров, но подписка включена - отключаем
            if campaigns.isEmpty {
                if let setting = MonetizationDatabase.botSetting(for: botName, logger: logger, env: env),
                   setting.requireSubscription {
                    MonetizationDatabase.setRequireSubscription(
                        botName: botName,
                        require: false,
                        logger: logger,
                        env: env
                    )
                    logger.info("Синхронизация: у бота \(botName) нет активных спонсоров, подписка автоматически отключена")
                }
            }
        }
    }

    private func buildStatusText(logger: Logger, env: Environment) -> String {
        // Синхронизируем состояние перед показом статуса
        syncBotSubscriptionSettings(logger: logger, env: env)
        
        let userStats = MonetizationDatabase.userStats(logger: logger, env: env)
        var lines: [String] = []
        lines.append("📊 Статус монетизации:")

        if userStats.isEmpty {
            lines.append("- Пока нет записей о пользователях (user_sessions пуст).")
        } else {
            lines.append("- Пользователи по ботам:")
            for (bot, count) in userStats.sorted(by: { $0.key < $1.key }) {
                lines.append("  • \(bot): \(count)")
            }
        }

        // Покажем, для каких ботов включена обязательная подписка
        let managedBotsEnv = Environment.get("NOWCONTROLLERBOT_BROADCAST_BOTS") ?? ""
        let managedBots = managedBotsEnv
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if managedBots.isEmpty {
            lines.append("")
            lines.append("NOWCONTROLLERBOT_BROADCAST_BOTS не задан — список управляемых ботов пуст.")
            return lines.joined(separator: "\n")
        }

        lines.append("")
        lines.append("⚙️ Настройки обязательной подписки:")
        for bot in managedBots {
            let sponsorCount = MonetizationDatabase.sponsorCount(for: bot, logger: logger, env: env)
            if let setting = MonetizationDatabase.botSetting(for: bot, logger: logger, env: env) {
                let flag = setting.requireSubscription ? "ON" : "OFF"
                lines.append("  • \(bot): \(flag) (спонсоров: \(sponsorCount))")
            } else {
                lines.append("  • \(bot): (не настроено, по умолчанию OFF) (спонсоров: \(sponsorCount))")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func handleSetRequireCommand(text: String, logger: Logger, env: Environment) -> String {
        // Формат: /set_require <bot> <on|off>
        let parts = text.split(separator: " ").map { String($0) }
        guard parts.count >= 3 else {
            return "Использование: /set_require <bot_name> <on|off>\nНапример: /set_require Roundsvideobot on"
        }

        let botName = parts[1]
        let flagRaw = parts[2].lowercased()

        let require: Bool
        if flagRaw == "on" || flagRaw == "1" || flagRaw == "true" {
            require = true
        } else if flagRaw == "off" || flagRaw == "0" || flagRaw == "false" {
            require = false
        } else {
            return "Второй параметр должен быть on или off. Пример: /set_require Roundsvideobot on"
        }

        MonetizationDatabase.setRequireSubscription(
            botName: botName,
            require: require,
            logger: logger,
            env: env
        )

        let statusText = require ? "включена" : "выключена"
        return "Для бота \(botName) обязательная подписка \(statusText)."
    }

    private func handleAddSponsorCommand(text: String, logger: Logger, env: Environment) -> String {
        // Формат: /add_sponsor <bot> <@канал|ссылка> <days|0>
        let parts = text.split(separator: " ").map { String($0) }
        guard parts.count >= 4 else {
            return "Использование: /add_sponsor <bot_name> <@канал|ссылка> <days|0>\nНапример: /add_sponsor Roundsvideobot @mychannel 7"
        }

        let botName = parts[1]
        let rawChannel = parts[2]
        let daysRaw = parts[3]

        guard let normalized = normalizeChannelIdentifier(rawChannel) else {
            return "Не удалось распознать канал из '\(rawChannel)'. Используй @username или ссылку https://t.me/username"
        }

        let expiresAt: Int?
        if let days = Int(daysRaw), days > 0 {
            let now = Int(Date().timeIntervalSince1970)
            expiresAt = now + days * 24 * 60 * 60
        } else {
            expiresAt = nil
        }

        MonetizationDatabase.addSponsorCampaign(
            botName: botName,
            channelUsername: normalized,
            expiresAt: expiresAt,
            logger: logger,
            env: env
        )

        if let expires = expiresAt {
            let days = Int((expires - Int(Date().timeIntervalSince1970)) / (24 * 60 * 60))
            return "Добавлен спонсор @\(normalized) для бота \(botName) на \(days) дн."
        } else {
            return "Добавлен спонсор @\(normalized) для бота \(botName) без срока окончания."
        }
    }

    private func handleListSponsorsCommand(text: String, logger: Logger, env: Environment) -> String {
        // Формат: /list_sponsors <bot>
        let parts = text.split(separator: " ").map { String($0) }
        guard parts.count >= 2 else {
            return "Использование: /list_sponsors <bot_name>\nНапример: /list_sponsors Roundsvideobot"
        }

        let botName = parts[1]
        let campaigns = MonetizationDatabase.activeCampaigns(for: botName, logger: logger, env: env)

        if campaigns.isEmpty {
            return "Для бота \(botName) нет активных спонсорских кампаний."
        }

        var lines: [String] = []
        lines.append("Активные спонсоры для \(botName):")

        let now = Int(Date().timeIntervalSince1970)
        for campaign in campaigns {
            let name = campaign.channelUsername
            if let expires = campaign.expiresAt {
                let remainingSeconds = max(0, expires - now)
                let days = remainingSeconds / (24 * 60 * 60)
                lines.append("- @\(name) (осталось примерно \(days) дн.)")
            } else {
                lines.append("- @\(name) (без срока)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func buildMainKeyboard(logger: Logger, env: Environment) -> ReplyKeyboardMarkup {
        // Синхронизируем состояние перед построением клавиатуры
        syncBotSubscriptionSettings(logger: logger, env: env)
        
        var keyboardRows: [[KeyboardButton]] = []
        
        // Первая линия: Статус и Спонсор
        keyboardRows.append([
            KeyboardButton(text: "📊 Статус"),
            KeyboardButton(text: "➕ Спонсор")
        ])
        
        // Получаем список всех управляемых ботов
        let managedBotsEnv = Environment.get("NOWCONTROLLERBOT_BROADCAST_BOTS") ?? ""
        let managedBots = managedBotsEnv
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        // Получаем список ботов со спонсорами
        let botsWithSponsors = MonetizationDatabase.botsWithActiveSponsors(logger: logger, env: env)
        
        // Собираем кнопки для всех ботов (по две в ряд):
        // ✅ = статус "включено" (нажатие выключает)
        // ⛔️ = статус "выключено" (нажатие включает)
        var currentRow: [KeyboardButton] = []
        for botName in managedBots {
            let hasSponsors = botsWithSponsors.contains(botName)
            var buttonText: String?
            
            if let setting = MonetizationDatabase.botSetting(for: botName, logger: logger, env: env) {
                let displayName = Self.displayName(for: botName)
                if setting.requireSubscription {
                    // Если включено - показываем статус ✅
                    buttonText = "✅ \(displayName)"
                } else if hasSponsors {
                    // Если выключено, но есть спонсоры - показываем статус ⛔️
                    buttonText = "⛔️ \(displayName)"
                }
            } else if hasSponsors {
                // Если настройки нет, но есть спонсоры - показываем статус ⛔️ (выключено)
                let displayName = Self.displayName(for: botName)
                buttonText = "⛔️ \(displayName)"
            }
            
            if let text = buttonText {
                currentRow.append(KeyboardButton(text: text))
                
                // Если набрали 2 кнопки в ряд - добавляем строку и начинаем новую
                if currentRow.count == 2 {
                    keyboardRows.append(currentRow)
                    currentRow = []
                }
            }
        }
        
        // Добавляем оставшуюся кнопку, если она одна
        if !currentRow.isEmpty {
            keyboardRows.append(currentRow)
        }
        
        return ReplyKeyboardMarkup(
            keyboard: keyboardRows,
            resize_keyboard: true,
            one_time_keyboard: false
        )
    }

    private func handleDeleteSponsorCommand(text: String, logger: Logger, env: Environment) -> String {
        // Формат: /delete_sponsor <bot> <@канал>
        let parts = text.split(separator: " ").map { String($0) }
        guard parts.count >= 3 else {
            return "Использование: /delete_sponsor <bot_name> <@канал>\nНапример: /delete_sponsor Roundsvideobot @mychannel"
        }

        let botName = parts[1]
        let rawChannel = parts[2]
        
        guard rawChannel.hasPrefix("@") else {
            return "Канал должен начинаться с @. Пример: /delete_sponsor \(botName) @mychannel"
        }
        
        let channelUsername = String(rawChannel.dropFirst())
        
        let campaigns = MonetizationDatabase.activeCampaigns(for: botName, logger: logger, env: env)
        
        if let campaign = campaigns.first(where: { $0.channelUsername == channelUsername }) {
            MonetizationDatabase.deactivateCampaign(id: campaign.id, logger: logger, env: env)
            
            // Проверяем, остались ли еще активные спонсоры у бота
            let remainingCampaigns = MonetizationDatabase.activeCampaigns(for: botName, logger: logger, env: env)
            
            var reply = "Спонсор @\(channelUsername) удалён для бота \(botName)."
            
            // Если не осталось активных спонсоров - автоматически отключаем подписку
            if remainingCampaigns.isEmpty {
                MonetizationDatabase.setRequireSubscription(
                    botName: botName,
                    require: false,
                    logger: logger,
                    env: env
                )
                reply += "\n\n⚠️ У бота не осталось активных спонсоров. Обязательная подписка автоматически отключена."
            }
            
            return reply
        } else {
            return "Спонсор @\(channelUsername) не найден среди активных кампаний для бота \(botName)."
        }
    }

    // MARK: - Parsing helpers

    /// Принимает @username или ссылку https://t.me/username[/...]
    /// Возвращает username без @.
    private func normalizeChannelIdentifier(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("@") {
            let trimmed = String(value.dropFirst())
            return trimmed.isEmpty ? nil : trimmed
        }

        if value.hasPrefix("https://t.me/") || value.hasPrefix("http://t.me/") {
            // Обрезаем протокол и домен
            if let range = value.range(of: "t.me/") {
                let after = value[range.upperBound...]
                let usernamePart = after.split(separator: "/").first ?? ""
                let trimmed = String(usernamePart)
                return trimmed.isEmpty ? nil : trimmed
            }
        }

        return nil
    }
}

// MARK: - Helper Functions

private func sendTelegramMessage(
    token: String,
    chatId: Int64,
    text: String,
    client: Client,
    replyMarkup: ReplyKeyboardMarkup? = nil
) async throws -> Bool {
    struct Payload: Content {
        let chat_id: Int64
        let text: String
        let disable_web_page_preview: Bool
        let reply_markup: ReplyKeyboardMarkup?
    }

    let payload = Payload(chat_id: chatId, text: text, disable_web_page_preview: false, reply_markup: replyMarkup)
    let url = "https://api.telegram.org/bot\(token)/sendMessage"
    let res = try await client.post(URI(string: url)) { req in
        try req.content.encode(payload, as: .json)
    }
    return res.status == .ok
}

// MARK: - Telegram Keyboard Models

struct KeyboardButton: Content {
    let text: String
}

struct ReplyKeyboardMarkup: Content {
    let keyboard: [[KeyboardButton]]
    let resize_keyboard: Bool
    let one_time_keyboard: Bool
}

