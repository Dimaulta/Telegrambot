import Foundation

struct AntispamNowBotResult {
    let responseText: String
    let media: AntispamNowMediaPayload?
    let meta: AntispamNowBotMeta
}

struct AntispamNowBotMeta {
    let mode: AntispamNowMediaKind
    let prompt: String
    let referenceFileId: String?
}

struct AntispamNowMediaPayload {
    let kind: AntispamNowMediaKind
    let url: String?
    let caption: String?
}

enum AntispamNowMediaKind: String {
    case nightMode
    case captcha
    case channelBlock
}


