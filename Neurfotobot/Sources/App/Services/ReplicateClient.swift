import Vapor
import Foundation

struct ReplicateClient {
    struct TrainingResponse: Decodable {
        let id: String
        let status: String
        let urls: URLs
        let output: TrainingOutput?

        struct URLs: Decodable {
            let get: String
        }
    }

    struct TrainingOutput: Decodable {
        let version: String?
    }

    struct PredictionResponse: Decodable {
        let id: String
        let status: String
        let output: [String]?
    }

    private let token: String
    private let trainingVersion: String
    private let predictionModel: String
    private let modelOwner: String
    private let trainingModelOwner: String
    private let trainingModelName: String
    private let trainingVersionId: String
    private let destinationModelSlug: String
    private let httpClient: Client
    private let logger: Logger

    init(application: Application, logger: Logger) throws {
        guard let token = Environment.get("REPLICATE_API_TOKEN"), !token.isEmpty else {
            throw Abort(.internalServerError, reason: "REPLICATE_API_TOKEN is not set")
        }
        guard let trainingVersion = Environment.get("REPLICATE_TRAINING_VERSION"), !trainingVersion.isEmpty else {
            throw Abort(.internalServerError, reason: "REPLICATE_TRAINING_VERSION is not set")
        }
        guard let predictionModel = Environment.get("REPLICATE_MODEL_VERSION"), !predictionModel.isEmpty else {
            throw Abort(.internalServerError, reason: "REPLICATE_MODEL_VERSION is not set")
        }
        guard let owner = Environment.get("REPLICATE_MODEL_OWNER"), !owner.isEmpty else {
            throw Abort(.internalServerError, reason: "REPLICATE_MODEL_OWNER is not set")
        }
        guard let destinationSlug = Environment.get("REPLICATE_DESTINATION_MODEL_SLUG"), !destinationSlug.isEmpty else {
            throw Abort(.internalServerError, reason: "REPLICATE_DESTINATION_MODEL_SLUG is not set")
        }

        self.token = token
        self.trainingVersion = trainingVersion
        self.predictionModel = predictionModel
        self.modelOwner = owner
        self.destinationModelSlug = destinationSlug.lowercased()
        self.httpClient = application.client
        self.logger = logger

        let versionComponents = trainingVersion.split(separator: ":")
        guard versionComponents.count == 2 else {
            throw Abort(.internalServerError, reason: "REPLICATE_TRAINING_VERSION must be in owner/model:version format")
        }
        let modelSlug = versionComponents[0]
        self.trainingVersionId = String(versionComponents[1])

        let modelComponents = modelSlug.split(separator: "/")
        guard modelComponents.count == 2 else {
            throw Abort(.internalServerError, reason: "REPLICATE_TRAINING_VERSION model slug must be owner/model")
        }
        self.trainingModelOwner = String(modelComponents[0])
        self.trainingModelName = String(modelComponents[1])
    }

    func startTraining(destinationModel: String, datasetURL: String, conceptName: String) async throws -> TrainingResponse {
        struct Payload: Encodable {
            let input: Input
            let destination: String

            struct Input: Encodable {
                let input_images: String
                let trigger_word: String
                let training_steps: Int
            }
        }

        let payload = Payload(
            input: .init(
                input_images: datasetURL,
                trigger_word: conceptName,
                training_steps: 800
            ),
            destination: destinationModel
        )

        let response = try await request(
            method: .POST,
            path: "/v1/models/\(trainingModelOwner)/\(trainingModelName)/versions/\(trainingVersionId)/trainings",
            body: try JSONEncoder().encode(payload)
        )

        return try decode(TrainingResponse.self, from: response)
    }

    func fetchTraining(id: String) async throws -> TrainingResponse {
        let response = try await request(method: .GET, path: "/v1/trainings/\(id)")
        return try decode(TrainingResponse.self, from: response)
    }

    func generateImages(modelVersion: String, prompt: String, negativePrompt: String? = nil, numOutputs: Int = 1) async throws -> PredictionResponse {
        struct Payload: Encodable {
            let version: String
            let input: Input

            struct Input: Encodable {
                let prompt: String
                let negative_prompt: String?
                let num_outputs: Int
                let guidance_scale: Double
            }
        }

        let payload = Payload(
            version: modelVersion,
            input: .init(
                prompt: prompt,
                negative_prompt: negativePrompt,
                num_outputs: numOutputs,
                guidance_scale: 3.5
            )
        )

        let response = try await request(
            method: .POST,
            path: "/v1/predictions",
            body: try JSONEncoder().encode(payload)
        )

        return try decode(PredictionResponse.self, from: response)
    }

    func waitForPrediction(id: String) async throws -> PredictionResponse {
        var consecutiveErrors = 0
        let maxConsecutiveErrors = 3
        
        while true {
            do {
                let response = try await request(method: .GET, path: "/v1/predictions/\(id)")
                let decoded = try decode(PredictionResponse.self, from: response)
                consecutiveErrors = 0 // Сбрасываем счётчик при успехе
                
                switch decoded.status.lowercased() {
                case "succeeded", "failed", "canceled":
                    return decoded
                default:
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
            } catch {
                consecutiveErrors += 1
                if consecutiveErrors >= maxConsecutiveErrors {
                    logger.error("Failed to fetch prediction \(id) \(consecutiveErrors) times: \(error)")
                    throw error
                }
                // При ошибке ждём немного дольше перед следующим запросом
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func deleteModel(destinationModel: String) async throws {
        _ = try await request(method: .DELETE, path: "/v1/models/\(destinationModel)")
    }

    private func request(method: HTTPMethod, path: String, body: Data? = nil) async throws -> ClientResponse {
        let url = URI(string: "https://api.replicate.com\(path)")
        var request = ClientRequest(method: method, url: url)
        request.headers.add(name: .authorization, value: "Bearer \(token)")
        request.headers.add(name: .accept, value: "application/json")
        if let body {
            request.headers.add(name: .contentType, value: "application/json")
            request.body = .init(data: body)
        }

        let response = try await httpClient.send(request)
        
        if !(200..<300).contains(response.status.code) {
            let errorBody = response.body.flatMap { buffer -> String in
                var bodyCopy = buffer
                return bodyCopy.readString(length: bodyCopy.readableBytes) ?? ""
            } ?? ""
            logger.error("Replicate API error \(response.status) \(path): \(errorBody.prefix(200))")
            throw Abort(response.status, reason: errorBody)
        }
        return response
    }

    private func decode<T: Decodable>(_ type: T.Type, from response: ClientResponse) throws -> T {
        guard let body = response.body else {
            logger.error("Replicate API returned empty response body")
            throw Abort(.badRequest, reason: "Empty response body from Replicate")
        }
        let data = body.getData(at: 0, length: body.readableBytes) ?? Data()
        
        guard !data.isEmpty else {
            logger.error("Replicate API returned empty data")
            throw Abort(.badRequest, reason: "Empty data from Replicate")
        }
        
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let bodyString = String(data: data, encoding: .utf8) ?? "<unable to decode>"
            logger.error("Failed to decode Replicate response: \(error)")
            logger.error("Response body (first 500 chars): \(bodyString.prefix(500))")
            logger.error("Response body length: \(data.count) bytes")
            throw Abort(.badRequest, reason: "Invalid JSON from Replicate")
        }
    }

    func destinationModelName(for chatId: Int64) -> String {
        let sanitizedOwner = modelOwner.lowercased()
        return "\(sanitizedOwner)/\(destinationModelSlug)"
    }

    var defaultPredictionVersion: String {
        predictionModel
    }

    func deleteModelVersion(id: String) async throws {
        let path = "/v1/models/\(modelOwner.lowercased())/\(destinationModelSlug)/versions/\(id)"
        do {
            _ = try await request(method: .DELETE, path: path)
        } catch let error as AbortError {
            // Если модель уже удалена на стороне Replicate (404), считаем это успешным удалением
            if error.status == .notFound {
                logger.warning("Replicate model version \(id) not found during delete; treating as already deleted.")
                return
            }
            throw error
        } catch {
            throw error
        }
    }

    func findModelVersion(for chatId: Int64) async throws -> String? {
        struct ModelResponse: Decodable {
            struct Version: Decodable {
                let id: String
                let created_at: String?
            }
            let versions: [Version]?
        }

        let path = "/v1/models/\(modelOwner.lowercased())/\(destinationModelSlug)"
        
        do {
            let response = try await request(method: .GET, path: path)
            let model = try decode(ModelResponse.self, from: response)
            
            // Получаем последнюю версию (версии отсортированы по дате создания, последняя - первая)
            // ВАЖНО: Это упрощённый подход - берём последнюю версию
            // Для точного определения нужна версия с trigger word "user{chatId}"
            // В будущем можно улучшить, сохраняя соответствие версия -> chatId в базе данных
            guard let versions = model.versions, !versions.isEmpty else {
                return nil
            }
            
            // Берём последнюю версию (самую новую)
            // TODO: Улучшить логику - проверять trigger word каждой версии
            return versions.first?.id
        } catch {
            logger.warning("Failed to find model version for chatId=\(chatId): \(error)")
            return nil
        }
    }
}

