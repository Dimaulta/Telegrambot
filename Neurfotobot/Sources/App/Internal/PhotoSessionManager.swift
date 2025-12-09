import Foundation

actor PhotoSessionManager {
    struct PhotoRecord {
        let path: String
    }

    struct Session {
        enum TrainingState: String {
            case idle
            case training
            case ready
            case failed
        }
        
        enum PromptCollectionState: String {
            case idle // Не собираем промпт
            case styleSelected // Стиль выбран, ждём пол
            case genderSelected // Пол выбран, ждём место
            case locationSelected // Место выбрано, ждём одежду
            case clothingSelected // Одежда выбрана, ждём дополнительные детали
            case readyToGenerate // Всё собрано, готово к генерации
        }

        var photos: [PhotoRecord] = []
        var trainingState: TrainingState = .idle
        var datasetPath: String?
        var trainingId: String?
        var modelVersion: String?
        var triggerWord: String? // Сохраняем trigger word для использования в промптах
        var prompt: String?
        var selectedStyle: String? // Выбранный стиль генерации
        var translatedPrompt: String? // Переведённый промпт (чтобы не переводить дважды)
        var lastActivityAt: Date? // Время последней активности пользователя
        
        // Данные для многошагового сбора промпта
        var promptCollectionState: PromptCollectionState = .idle
        var userGender: String? // "male" или "female"
        var userLocation: String? // Место, где пользователь хочет себя увидеть
        var userClothing: String? // Одежда и её цвет
        var additionalDetails: String? // Дополнительные детали от пользователя
    }

    static let shared = PhotoSessionManager()

    private var sessions: [Int64: Session] = [:]

    func addPhoto(path: String, for chatId: Int64) -> Int {
        var session = sessions[chatId] ?? Session()
        session.photos.append(PhotoRecord(path: path))
        sessions[chatId] = session
        return session.photos.count
    }

    func getPhotos(for chatId: Int64) -> [PhotoRecord] {
        sessions[chatId]?.photos ?? []
    }

    func reset(for chatId: Int64) {
        sessions[chatId] = nil
    }

    func ensureSession(for chatId: Int64) -> Session {
        let session = sessions[chatId] ?? Session()
        sessions[chatId] = session
        return session
    }

    func clearPhotos(for chatId: Int64) {
        guard var session = sessions[chatId] else { return }
        session.photos = []
        sessions[chatId] = session
    }

    func getTrainingState(for chatId: Int64) -> Session.TrainingState {
        sessions[chatId]?.trainingState ?? .idle
    }

    func isReadyForPrompt(for chatId: Int64) -> Bool {
        sessions[chatId]?.trainingState == .ready
    }

    func setPrompt(_ prompt: String, for chatId: Int64) {
        var session = sessions[chatId] ?? Session()
        session.prompt = prompt
        sessions[chatId] = session
    }

    func getPrompt(for chatId: Int64) -> String? {
        sessions[chatId]?.prompt
    }

    func clearPrompt(for chatId: Int64) {
        guard var session = sessions[chatId] else { return }
        session.prompt = nil
        sessions[chatId] = session
    }

    func setTrainingState(_ state: Session.TrainingState, for chatId: Int64) {
        var session = sessions[chatId] ?? Session()
        session.trainingState = state
        sessions[chatId] = session
    }

    func setDatasetPath(_ path: String?, for chatId: Int64) {
        var session = sessions[chatId] ?? Session()
        session.datasetPath = path
        sessions[chatId] = session
    }

    func getDatasetPath(for chatId: Int64) -> String? {
        sessions[chatId]?.datasetPath
    }

    func setTrainingId(_ id: String?, for chatId: Int64) {
        var session = sessions[chatId] ?? Session()
        session.trainingId = id
        sessions[chatId] = session
    }

    func getTrainingId(for chatId: Int64) -> String? {
        sessions[chatId]?.trainingId
    }

    func setModelVersion(_ version: String?, for chatId: Int64) {
        var session = sessions[chatId] ?? Session()
        session.modelVersion = version
        sessions[chatId] = session
    }

    func getModelVersion(for chatId: Int64) -> String? {
        sessions[chatId]?.modelVersion
    }

    func setTriggerWord(_ word: String, for chatId: Int64) {
        var session = sessions[chatId] ?? Session()
        session.triggerWord = word
        sessions[chatId] = session
    }

    func getTriggerWord(for chatId: Int64) -> String? {
        sessions[chatId]?.triggerWord
    }

    func setStyle(_ style: String?, for chatId: Int64) {
        var session = sessions[chatId] ?? Session()
        session.selectedStyle = style
        sessions[chatId] = session
    }

    func getStyle(for chatId: Int64) -> String? {
        sessions[chatId]?.selectedStyle
    }
    
    func setPromptCollectionState(_ state: Session.PromptCollectionState, for chatId: Int64) {
        var session = sessions[chatId] ?? Session()
        session.promptCollectionState = state
        sessions[chatId] = session
    }
    
    func getPromptCollectionState(for chatId: Int64) -> Session.PromptCollectionState {
        sessions[chatId]?.promptCollectionState ?? .idle
    }
    
    func setUserGender(_ gender: String?, for chatId: Int64) {
        var session = sessions[chatId] ?? Session()
        session.userGender = gender
        sessions[chatId] = session
    }
    
    func getUserGender(for chatId: Int64) -> String? {
        sessions[chatId]?.userGender
    }
    
    func setUserLocation(_ location: String?, for chatId: Int64) {
        var session = sessions[chatId] ?? Session()
        session.userLocation = location
        sessions[chatId] = session
    }
    
    func getUserLocation(for chatId: Int64) -> String? {
        sessions[chatId]?.userLocation
    }
    
    func setUserClothing(_ clothing: String?, for chatId: Int64) {
        var session = sessions[chatId] ?? Session()
        session.userClothing = clothing
        sessions[chatId] = session
    }
    
    func getUserClothing(for chatId: Int64) -> String? {
        sessions[chatId]?.userClothing
    }
    
    func setAdditionalDetails(_ details: String?, for chatId: Int64) {
        var session = sessions[chatId] ?? Session()
        session.additionalDetails = details
        sessions[chatId] = session
    }
    
    func getAdditionalDetails(for chatId: Int64) -> String? {
        sessions[chatId]?.additionalDetails
    }
    
    func clearPromptCollectionData(for chatId: Int64) {
        guard var session = sessions[chatId] else { return }
        session.promptCollectionState = .idle
        session.userGender = nil
        session.userLocation = nil
        session.userClothing = nil
        session.additionalDetails = nil
        sessions[chatId] = session
    }
    
    func setTranslatedPrompt(_ prompt: String?, for chatId: Int64) {
        var session = sessions[chatId] ?? Session()
        session.translatedPrompt = prompt
        sessions[chatId] = session
    }
    
    func getTranslatedPrompt(for chatId: Int64) -> String? {
        sessions[chatId]?.translatedPrompt
    }
    
    func setLastActivity(for chatId: Int64) {
        var session = sessions[chatId] ?? Session()
        session.lastActivityAt = Date()
        sessions[chatId] = session
    }
    
    func getLastActivity(for chatId: Int64) -> Date? {
        sessions[chatId]?.lastActivityAt
    }
    
    /// Возвращает все сессии с их chatId для периодической очистки
    func getAllSessions() -> [(chatId: Int64, session: Session)] {
        sessions.map { (chatId: $0.key, session: $0.value) }
    }
}

