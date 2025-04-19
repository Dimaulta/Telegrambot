import Vapor

struct CropData: Content {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let currentTime: Double
    let scale: Double
}

struct UploadData: Content {
    var video: File
    var cropData: String
    var chatId: String
} 