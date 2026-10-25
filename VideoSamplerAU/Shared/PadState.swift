import Foundation

struct PadState: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var midiNote: Int
    var bookmarkData: Data?
    var fileName: String?
    var clipStart: Double
    var clipEnd: Double
    var duration: Double
    var colorIndex: Int

    init(
        id: UUID = UUID(),
        name: String,
        midiNote: Int,
        bookmarkData: Data? = nil,
        fileName: String? = nil,
        clipStart: Double = 0,
        clipEnd: Double = 1,
        duration: Double = 1,
        colorIndex: Int
    ) {
        self.id = id
        self.name = name
        self.midiNote = min(127, max(0, midiNote))
        self.bookmarkData = bookmarkData
        self.fileName = fileName
        self.clipStart = clipStart
        self.clipEnd = clipEnd
        self.duration = max(0.05, duration)
        self.colorIndex = colorIndex
        normalize()
    }

    mutating func normalize() {
        duration = max(0.05, duration.isFinite ? duration : 1)
        clipStart = min(max(0, clipStart.isFinite ? clipStart : 0), duration - 0.05)
        clipEnd = min(max(clipStart + 0.05, clipEnd.isFinite ? clipEnd : duration), duration)
        midiNote = min(127, max(0, midiNote))
    }

    func resolvingURL() -> URL? {
        guard let bookmarkData else { return nil }
        var stale = false
        return try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    static let defaults: [PadState] = {
        let definitions: [(String, Int)] = [
            // The first ten slots follow the physical Fingersonic Beats layout.
            ("OPEN HAT", 46), ("CRASH", 49), ("CLOSED HAT", 42), ("SNARE", 38),
            ("TOM 1", 48), ("KICK", 36), ("TOM 2", 45), ("RIDE", 53),
            ("FLOOR TOM", 43), ("CRASH 2", 57)
        ]
        return definitions.enumerated().map { index, value in
            PadState(name: value.0, midiNote: value.1, colorIndex: index)
        }
    }()

    /// Carries clips from the original generic 4x4 layout into the physical
    /// Fingersonic layout so sessions made with v0.2 remain usable.
    static func migratingLegacyLayout(_ source: [PadState]) -> [PadState] {
        let physicalNames = defaults.map(\.name)
        if source.count > defaults.count,
           Array(source.prefix(defaults.count)).map(\.name) == physicalNames {
            return Array(source.prefix(defaults.count))
        }

        let legacyNames = [
            "KICK", "SNARE", "CLAP", "RIM", "CLOSED HAT", "OPEN HAT", "CRASH", "RIDE",
            "LOW TOM", "MID TOM", "HIGH TOM", "COWBELL", "PAD 13", "PAD 14", "PAD 15", "PAD 16"
        ]
        guard source.map(\.name) == legacyNames else { return source }

        let sourceIndices = [5, 6, 4, 1, 10, 0, 9, 7, 8, 12]
        return defaults.enumerated().map { destination, template in
            let old = source[sourceIndices[destination]]
            var migrated = template
            migrated.id = old.id
            migrated.bookmarkData = old.bookmarkData
            migrated.fileName = old.fileName
            migrated.clipStart = old.clipStart
            migrated.clipEnd = old.clipEnd
            migrated.duration = old.duration
            migrated.normalize()
            return migrated
        }
    }
}

enum VideoSamplerStateKeys {
    static let pads = "com.fingersonic.videoSampler.pads"
    static let gain = "com.fingersonic.videoSampler.gain"
}
