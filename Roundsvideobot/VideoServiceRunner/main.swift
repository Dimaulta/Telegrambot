import Vapor
import VideoService

@main
struct Main {
    static func main() async throws {
        try await App.run()
    }
} 