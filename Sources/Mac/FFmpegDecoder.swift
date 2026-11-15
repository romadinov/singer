import CryptoKit
import Foundation

/// Converts formats Core Audio can't read into a cached file it can:
/// lossless sources become FLAC (bit-exact), lossy sources become 32-bit float CAF.
enum FFmpegDecoder {
    enum DecodeError: LocalizedError {
        case ffmpegMissing
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .ffmpegMissing: "This format needs ffmpeg — install it with `brew install ffmpeg`."
            case .failed(let msg): "ffmpeg failed: \(msg)"
            }
        }
    }

    static let cacheDirectory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Singer/decoded", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func outputExtension(for ext: String) -> String {
        AudioFormats.losslessExtensions.contains(ext) ? "flac" : "caf"
    }

    static func decode(_ url: URL) async throws -> URL {
        guard let ffmpeg = AudioFormats.ffmpegPath else { throw DecodeError.ffmpegMissing }
        let ext = url.pathExtension.lowercased()
        let lossless = AudioFormats.losslessExtensions.contains(ext)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = "\(url.path)|\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(attrs[.size] ?? 0)"
        let hash = SHA256.hash(data: Data(stamp.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let outExt = lossless ? "flac" : "caf"
        let output = cacheDirectory.appendingPathComponent("\(hash).\(outExt)")
        if FileManager.default.fileExists(atPath: output.path) { return output }

        let partial = cacheDirectory.appendingPathComponent("\(hash).part.\(outExt)")
        var args = ["-nostdin", "-v", "error", "-y", "-i", url.path, "-vn", "-map_metadata", "-1"]
        if lossless {
            args += ["-c:a", "flac", "-compression_level", "0"]
            if ext == "dsf" || ext == "dff" { args += ["-sample_fmt", "s32", "-ar", "176400"] }
        } else {
            args += ["-c:a", "pcm_f32le"]
        }
        args.append(partial.path)

        try await run(ffmpeg, args)
        try FileManager.default.moveItem(at: partial, to: output)
        return output
    }

    /// Drop decoded files that haven't been used for a few days.
    static func pruneCache(olderThan days: Double = 3) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-days * 86400)
        let files = (try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentAccessDateKey])) ?? []
        for f in files {
            let accessed = (try? f.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate ?? .distantPast
            if accessed < cutoff || f.lastPathComponent.contains(".part.") { try? fm.removeItem(at: f) }
        }
    }

    private static func run(_ tool: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            p.terminationHandler = { proc in
                let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: DecodeError.failed(msg.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
