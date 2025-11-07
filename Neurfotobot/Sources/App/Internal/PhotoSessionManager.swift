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

        var photos: [PhotoRecord] = []
        var trainingState: TrainingState = .idle
        var datasetPath: String?
        var trainingId: String?
        var modelVersion: String?
        var prompt: String?
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
}

