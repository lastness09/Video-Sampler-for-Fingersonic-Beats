import Foundation

@main
enum VideoClipLoaderSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "VideoClipLoaderSmoke", code: 1)
        }
        let clip = try await VideoClipLoader.decode(
            url: URL(fileURLWithPath: CommandLine.arguments[1]),
            start: 0.05,
            end: 0.20
        )
        guard !clip.left.isEmpty,
              clip.left.count == clip.right.count,
              clip.sampleRate > 0 else {
            throw NSError(domain: "VideoClipLoaderSmoke", code: 2)
        }
        let expectedFrames = Int((0.20 - 0.05) * clip.sampleRate)
        guard abs(clip.left.count - expectedFrames) <= 2 else {
            throw NSError(
                domain: "VideoClipLoaderSmoke",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Decoded \(clip.left.count) frames; expected \(expectedFrames)."
                ]
            )
        }
        print("Video audio decode passed: \(clip.left.count) stereo frames @ \(clip.sampleRate) Hz")
    }
}
