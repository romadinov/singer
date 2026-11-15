import Foundation

struct Chapter: Identifiable, Hashable, Codable, Sendable {
    var id: Int { index }
    let index: Int
    let title: String
    let start: Double
    let duration: Double
}

struct Track: Identifiable, Codable, Sendable {
    var id = UUID()
    var url: URL
    /// Stable identity shared between Mac and iPhone (nil on the Mac; derived from the path there).
    var syncID: String?
    var title: String
    var artist: String?
    var album: String?
    var duration: Double = 0
    var sampleRate: Double = 0
    var channels: Int = 0
    var bitsPerSample: Int = 0
    var bitrateKbps: Int = 0
    var codec: String = ""
    var isLossless = false
    var chapters: [Chapter] = []
    var metadataLoaded = false

    init(url: URL) {
        self.url = url
        self.title = url.deletingPathExtension().lastPathComponent
    }

    var ext: String { url.pathExtension.lowercased() }
    /// Key for remembered playback positions.
    var positionKey: String { syncID ?? url.path }
    var displayTitle: String {
        if let artist, !artist.isEmpty { return "\(artist) - \(title)" }
        return title
    }
    /// Long-form content (audiobooks, podcasts) remembers where you stopped.
    var remembersPosition: Bool { ext == "m4b" || !chapters.isEmpty || duration > 20 * 60 }

    func chapterIndex(at time: Double) -> Int? {
        guard !chapters.isEmpty else { return nil }
        return chapters.lastIndex { $0.start <= time + 0.05 } ?? 0
    }
}

enum AudioFormats {
    /// Decoded natively by Core Audio / AVFoundation.
    static let native: Set<String> = [
        "mp3", "m4a", "m4b", "mp4", "aac", "alac", "flac",
        "wav", "wave", "aif", "aiff", "aifc", "caf",
    ]
    /// Decoded through ffmpeg (if installed) into a cached lossless/float file.
    static let viaFFmpeg: Set<String> = [
        "ape", "wv", "tta", "tak", "dsf", "dff", "ogg", "oga", "opus", "wma", "mka",
    ]
    static let losslessExtensions: Set<String> = [
        "flac", "wav", "wave", "aif", "aiff", "aifc", "ape", "wv", "tta", "tak", "dsf", "dff",
    ]
    static let playlists: Set<String> = ["m3u", "m3u8"]

    static let ffmpegPath: String? = findTool("ffmpeg")
    static let ffprobePath: String? = findTool("ffprobe")

    static var playable: Set<String> {
        ffmpegPath == nil ? native : native.union(viaFFmpeg)
    }

    static func isNative(_ ext: String) -> Bool { native.contains(ext) }

    private static func findTool(_ name: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/opt/local/bin"]
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds.rounded(.down))
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}
