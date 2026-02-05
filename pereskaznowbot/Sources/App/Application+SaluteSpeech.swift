import Vapor

extension Application {
    private struct SaluteSpeechAuthServiceKey: StorageKey {
        typealias Value = SaluteSpeechAuthService
    }
    
    private struct SaluteSpeechRecognitionServiceKey: StorageKey {
        typealias Value = SaluteSpeechRecognitionService
    }
    
    var saluteSpeechAuthService: SaluteSpeechAuthService {
        if let existing = storage[SaluteSpeechAuthServiceKey.self] {
            return existing
        }
        let service = SaluteSpeechAuthService(app: self)
        storage[SaluteSpeechAuthServiceKey.self] = service
        return service
    }
    
    var saluteSpeechRecognitionService: SaluteSpeechRecognitionService {
        if let existing = storage[SaluteSpeechRecognitionServiceKey.self] {
            return existing
        }
        let recognition = SaluteSpeechRecognitionService(app: self, authService: saluteSpeechAuthService)
        storage[SaluteSpeechRecognitionServiceKey.self] = recognition
        return recognition
    }
}
