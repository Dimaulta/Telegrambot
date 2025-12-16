import Vapor
import Foundation

actor SupabaseKeepAliveService {
    static let shared = SupabaseKeepAliveService()
    
    private var isRunning = false
    private let keepAliveIntervalDays: Int = 5
    private var lastPingTime: Date?
    
    private init() {}
    
    /// Запускает периодический keep-alive для Supabase
    /// Выполняет ping при старте и затем каждые 5 дней
    func startKeepAlive(application: Application) async {
        guard !isRunning else {
            application.logger.warning("SupabaseKeepAliveService: keep-alive уже запущен")
            return
        }
        
        isRunning = true
        application.logger.info("SupabaseKeepAliveService: запущен keep-alive для Supabase (интервал: \(keepAliveIntervalDays) дней)")
        
        // Выполняем ping при старте
        await performPing(application: application, isStartup: true)
        
        // Запускаем периодический ping
        Task.detached {
            while true {
                do {
                    // Ждём 5 дней перед следующим ping
                    let intervalSeconds = self.keepAliveIntervalDays * 24 * 3600
                    try await Task.sleep(nanoseconds: UInt64(intervalSeconds) * 1_000_000_000)
                    
                    await self.performPing(application: application, isStartup: false)
                } catch {
                    application.logger.error("SupabaseKeepAliveService: ошибка в периодической задаче: \(error)")
                    // При ошибке ждём час перед следующей попыткой
                    try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
                }
            }
        }
    }
    
    /// Выполняет ping к Supabase Storage API
    private func performPing(application: Application, isStartup: Bool) async {
        let logger = application.logger
        
        do {
            let storage = try SupabaseStorageClient(application: application)
            let startTime = Date()
            
            logger.info("SupabaseKeepAliveService: выполняю ping к Supabase Storage...")
            
            let success = await storage.ping()
            let duration = Date().timeIntervalSince(startTime)
            
            if success {
                lastPingTime = Date()
                if isStartup {
                    if duration > 5.0 {
                        logger.warning("SupabaseKeepAliveService: ping выполнен успешно, но занял \(String(format: "%.2f", duration)) секунд. Проект мог быть на паузе")
                    } else {
                        logger.info("SupabaseKeepAliveService: ping выполнен успешно за \(String(format: "%.2f", duration)) секунд")
                    }
                } else {
                    logger.info("SupabaseKeepAliveService: периодический ping выполнен успешно за \(String(format: "%.2f", duration)) секунд")
                }
            } else {
                logger.warning("SupabaseKeepAliveService: ping не удался. Проект может быть на паузе или недоступен")
            }
        } catch {
            logger.error("SupabaseKeepAliveService: ошибка при выполнении ping: \(error)")
            
            if isStartup {
                logger.warning("SupabaseKeepAliveService: не удалось выполнить ping при старте. Проект может быть на паузе - первый запрос пользователя может быть медленным")
            }
        }
    }
    
    /// Возвращает время последнего успешного ping
    func getLastPingTime() -> Date? {
        return lastPingTime
    }
}

