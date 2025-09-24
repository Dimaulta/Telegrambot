import Vapor

struct CropData: Content {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let scale: Double
} 