import Foundation

struct BananaNowBotResult {
    let responseText: String
    let media: BananaNowMediaPayload?
    let meta: BananaNowBotMeta
}

struct BananaNowBotMeta {
    let mode: BananaNowMediaKind
    let prompt: String
    let referenceFileId: String?
}

struct BananaNowMediaPayload {
    let kind: BananaNowMediaKind
    let url: String?
    let caption: String?
}

enum BananaNowMediaKind: String {
    case image
    case imageEdit
    case video
}


