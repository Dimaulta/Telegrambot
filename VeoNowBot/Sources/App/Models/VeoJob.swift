import Vapor

struct VeoJob: Content, Sendable {
    let id: String
    let status: VeoJobStatus
    let detail: String?
}

enum VeoJobStatus: String, Content, Sendable {
    case queued
    case processing
    case completed
    case failed
}

