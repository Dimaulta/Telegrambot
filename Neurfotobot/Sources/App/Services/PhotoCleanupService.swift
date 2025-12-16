import Vapor
import Foundation

actor PhotoCleanupService {
    static let shared = PhotoCleanupService()
    
    private var isRunning = false
    private let expirationHours: Int = 24
    private let cleanupIntervalHours: Int = 6
    
    private init() {}
    
    /// Запускает периодическую очистку фото
    func startPeriodicCleanup(application: Application, intervalHours: Int = 6) async {
        guard !isRunning else {
            application.logger.warning("PhotoCleanupService: периодическая очистка уже запущена")
            return
        }
        
        isRunning = true
        application.logger.info("PhotoCleanupService: запущена периодическая очистка фото (интервал: \(intervalHours) часов)")
        
        Task.detached {
            while true {
                do {
                    // Ждём перед первой проверкой (чтобы не нагружать при старте)
                    try await Task.sleep(nanoseconds: UInt64(intervalHours * 3600) * 1_000_000_000)
                    
                    await self.performCleanup(application: application)
                } catch {
                    application.logger.error("PhotoCleanupService: ошибка в периодической задаче: \(error)")
                    // При ошибке ждём час перед следующей попыткой
                    try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
                }
            }
        }
    }
    
    /// Выполняет очистку фото, которые не использовались более 24 часов
    func performCleanup(application: Application) async {
        let logger = application.logger
        logger.info("PhotoCleanupService: начинаю очистку фото")
        
        let allSessions = await PhotoSessionManager.shared.getAllSessions()
        logger.info("PhotoCleanupService: найдено \(allSessions.count) сессий для проверки")
        
        let expirationDate = Date().addingTimeInterval(-TimeInterval(expirationHours * 3600))
        var cleanedCount = 0
        var messageSentCount = 0
        var errorCount = 0
        
        for (chatId, session) in allSessions {
            // Проверяем условия для очистки
            guard await shouldCleanupSession(session: session, expirationDate: expirationDate, chatId: chatId, application: application) else {
                continue
            }
            
            // Удаляем фото из Supabase Storage
            do {
                let storage = try SupabaseStorageClient(application: application)
                for photo in session.photos {
                    do {
                        try await storage.delete(path: photo.path)
                        logger.info("PhotoCleanupService: удалено фото \(photo.path) для chatId=\(chatId)")
                    } catch {
                        logger.warning("PhotoCleanupService: не удалось удалить фото \(photo.path) для chatId=\(chatId): \(error)")
                        errorCount += 1
                    }
                }
                
                // Очищаем сессию в PhotoSessionManager
                await PhotoSessionManager.shared.reset(for: chatId)
                cleanedCount += 1
                
                // Отправляем сообщение пользователю
                if let token = Environment.get("NEURFOTOBOT_TOKEN"), !token.isEmpty {
                    let sent = await sendExpirationMessage(chatId: chatId, token: token, application: application)
                    if sent {
                        messageSentCount += 1
                    }
                }
            } catch {
                logger.error("PhotoCleanupService: ошибка при очистке для chatId=\(chatId): \(error)")
                errorCount += 1
            }
        }
        
        logger.info("PhotoCleanupService: очистка завершена. Удалено сессий: \(cleanedCount), отправлено сообщений: \(messageSentCount), ошибок: \(errorCount)")
    }
    
    /// Проверяет, нужно ли очищать сессию
    private func shouldCleanupSession(session: PhotoSessionManager.Session, expirationDate: Date, chatId: Int64, application: Application) async -> Bool {
        let logger = application.logger
        
        // 1. Проверяем, есть ли фото для удаления
        guard !session.photos.isEmpty else {
            return false
        }
        
        // 2. Проверяем состояние обучения - не удаляем если модель обучается или готова
        if session.trainingState == .training {
            logger.debug("PhotoCleanupService: пропускаем chatId=\(chatId) - модель в процессе обучения")
            return false
        }
        
        if session.trainingState == .ready {
            logger.debug("PhotoCleanupService: пропускаем chatId=\(chatId) - модель уже готова")
            return false
        }
        
        // 3. Проверяем время последней активности
        guard let lastActivity = session.lastActivityAt else {
            // Если lastActivityAt не установлен, считаем что фото старые (для обратной совместимости)
            logger.info("PhotoCleanupService: chatId=\(chatId) не имеет lastActivityAt, считаем фото устаревшими")
            return true
        }
        
        guard lastActivity < expirationDate else {
            logger.debug("PhotoCleanupService: пропускаем chatId=\(chatId) - активность была \(lastActivity)")
            return false
        }
        
        // 4. Проверяем подписку (с учётом fail-open стратегии)
        // Если require_subscription включен и есть активные спонсоры, проверяем подписку
        // Но если проверка не работает (fail-open), всё равно разрешаем очистку
        // Если подписка не требуется - удаляем по таймауту как обычно
        let (allowed, channels) = await MonetizationService.checkAccess(
            botName: "Neurfotobot",
            userId: chatId,
            logger: logger,
            env: application.environment,
            client: application.client
        )
        
        // Если channels пустой - значит либо подписка не требуется, либо нет активных спонсоров
        // В этом случае удаляем по таймауту как обычно
        if channels.isEmpty {
            logger.debug("PhotoCleanupService: chatId=\(chatId) - подписка не требуется или нет активных спонсоров, удаляем по таймауту")
            return true
        }
        
        // Если есть активные спонсоры и подписка подтверждена - пользователь активен, не удаляем
        if allowed {
            logger.debug("PhotoCleanupService: пропускаем chatId=\(chatId) - пользователь подписан на спонсоров")
            return false
        }
        
        // Если подписка требуется, но не подтверждена - удаляем (пользователь не использует сервис)
        logger.info("PhotoCleanupService: chatId=\(chatId) не подписан на спонсоров, удаляем фото")
        return true
    }
    
    /// Отправляет сообщение пользователю об истечении фото
    private func sendExpirationMessage(chatId: Int64, token: String, application: Application) async -> Bool {
        let message = """
Твои загруженные фотографии были удалены, так как прошло более 24 часов без активности.

Если хочешь обучить модель, загрузи фото заново и запусти обучение командой /train.
"""
        
        do {
            let url = URI(string: "https://api.telegram.org/bot\(token)/sendMessage")
            var request = ClientRequest(method: .POST, url: url)
            let payload: [String: Any] = [
                "chat_id": chatId,
                "text": message
            ]
            request.headers.add(name: .contentType, value: "application/json")
            request.body = try .init(data: JSONSerialization.data(withJSONObject: payload))
            
            let response = try await application.client.send(request)
            
            if response.status == .ok {
                application.logger.info("PhotoCleanupService: отправлено сообщение об истечении фото для chatId=\(chatId)")
                return true
            } else {
                application.logger.warning("PhotoCleanupService: не удалось отправить сообщение для chatId=\(chatId), статус: \(response.status)")
                return false
            }
        } catch {
            // Не критично, если пользователь удалил чат или заблокировал бота
            application.logger.debug("PhotoCleanupService: ошибка отправки сообщения для chatId=\(chatId): \(error)")
            return false
        }
    }
}

