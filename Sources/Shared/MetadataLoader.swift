import AVFoundation
import Foundation

enum MetadataLoader {
    static func load(_ input: Track) async -> Track {
        var t = input
        let url = t.url
        defer { t.metadataLoaded = true }

        if AudioFormats.isNative(t.ext) {
            readTechnicalInfo(into: &t)
            await readAssetMetadata(into: &t)
            if t.ext == "flac", let tags = FLACTags.read(url) { apply(tags, to: &t) }
        } else {
            #if os(macOS)
            if AudioFormats.ffprobePath != nil { FFprobe.read(into: &t) }
            #endif
        }

        if t.bitrateKbps == 0, t.duration > 0,
           let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            t.bitrateKbps = Int(Double(size) * 8 / t.duration / 1000)
        }
        if AudioFormats.losslessExtensions.contains(t.ext) { t.isLossless = true }
        return t
    }

    static func readTechnicalInfo(into t: inout Track) {
        guard let file = try? AVAudioFile(forReading: t.url) else { return }
        let fmt = file.fileFormat
        let asbd = fmt.streamDescription.pointee
        t.sampleRate = fmt.sampleRate
        t.channels = Int(fmt.channelCount)
        if fmt.sampleRate > 0 { t.duration = Double(file.length) / fmt.sampleRate }
        t.bitsPerSample = Int(asbd.mBitsPerChannel)
        switch asbd.mFormatID {
        case kAudioFormatMPEGLayer3: t.codec = "MP3"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: t.codec = "AAC"
        case kAudioFormatAppleLossless: t.codec = "ALAC"; t.isLossless = true
        case kAudioFormatFLAC: t.codec = "FLAC"; t.isLossless = true
        case kAudioFormatLinearPCM: t.codec = "PCM"; t.isLossless = true
        default: t.codec = t.ext.uppercased()
        }
        // Compressed lossless formats report 0 bits; the source bit depth hides in the flags.
        if t.bitsPerSample == 0, t.isLossless {
            switch asbd.mFormatFlags {
            case 1: t.bitsPerSample = 16
            case 2: t.bitsPerSample = 20
            case 3: t.bitsPerSample = 24
            case 4: t.bitsPerSample = 32
            default: break
            }
        }
    }

    private static func readAssetMetadata(into t: inout Track) async {
        let asset = AVURLAsset(url: t.url)
        if let items = try? await asset.load(.commonMetadata) {
            if let s = await string(items, .commonIdentifierTitle), !s.isEmpty { t.title = s }
            if let s = await string(items, .commonIdentifierArtist), !s.isEmpty { t.artist = s }
            if let s = await string(items, .commonIdentifierAlbumName), !s.isEmpty { t.album = s }
        }
        if t.duration == 0, let d = try? await asset.load(.duration), d.seconds.isFinite {
            t.duration = d.seconds
        }
        t.chapters = await chapters(of: asset)
    }

    private static func chapters(of asset: AVURLAsset) async -> [Chapter] {
        var groups = (try? await asset.loadChapterMetadataGroups(
            bestMatchingPreferredLanguages: Locale.preferredLanguages)) ?? []
        if groups.isEmpty,
           let locale = (try? await asset.load(.availableChapterLocales))?.first {
            groups = (try? await asset.loadChapterMetadataGroups(
                withTitleLocale: locale, containingItemsWithCommonKeys: [])) ?? []
        }
        var result: [Chapter] = []
        for (i, g) in groups.enumerated() {
            let title = await string(g.items, .commonIdentifierTitle) ?? "Chapter \(i + 1)"
            result.append(Chapter(index: i, title: title,
                                  start: g.timeRange.start.seconds,
                                  duration: g.timeRange.duration.seconds))
        }
        return result
    }

    private static func string(_ items: [AVMetadataItem], _ id: AVMetadataIdentifier) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first
        else { return nil }
        return try? await item.load(.stringValue)
    }

    static func apply(_ tags: [String: String], to t: inout Track) {
        if let s = tags["TITLE"], !s.isEmpty { t.title = s }
        if let s = tags["ARTIST"] ?? tags["ALBUM_ARTIST"] ?? tags["ALBUMARTIST"], !s.isEmpty { t.artist = s }
        if let s = tags["ALBUM"], !s.isEmpty { t.album = s }
    }
}

/// Minimal FLAC Vorbis-comment reader, used when AVFoundation returns no tags.
enum FLACTags {
    static func read(_ url: URL) -> [String: String]? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let magic = try? fh.read(upToCount: 4), magic == Data("fLaC".utf8) else { return nil }
        while let header = try? fh.read(upToCount: 4), header.count == 4 {
            let isLast = header[0] & 0x80 != 0
            let type = header[0] & 0x7F
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            if type == 4 {
                guard let block = try? fh.read(upToCount: length) else { return nil }
                return parseVorbisComment(block)
            }
            guard !isLast, let offset = try? fh.offset() else { return nil }
            try? fh.seek(toOffset: offset + UInt64(length))
        }
        return nil
    }

    private static func parseVorbisComment(_ d: Data) -> [String: String] {
        var pos = d.startIndex
        func u32() -> Int? {
            guard pos + 4 <= d.endIndex else { return nil }
            let v = Int(d[pos]) | Int(d[pos + 1]) << 8 | Int(d[pos + 2]) << 16 | Int(d[pos + 3]) << 24
            pos += 4
            return v
        }
        var tags: [String: String] = [:]
        guard let vendorLen = u32() else { return tags }
        pos += vendorLen
        guard let count = u32() else { return tags }
        for _ in 0..<count {
            guard let len = u32(), pos + len <= d.endIndex else { break }
            if let s = String(data: d[pos..<pos + len], encoding: .utf8),
               let eq = s.firstIndex(of: "=") {
                let key = s[..<eq].uppercased()
                if tags[key] == nil { tags[key] = String(s[s.index(after: eq)...]) }
            }
            pos += len
        }
        return tags
    }
}

#if os(macOS)
/// Metadata for formats Core Audio can't open (APE, WavPack, DSD, Ogg…).
enum FFprobe {
    static func read(into t: inout Track) {
        guard let probe = AudioFormats.ffprobePath else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: probe)
        p.arguments = ["-v", "error", "-print_format", "json",
                       "-show_format", "-show_streams", "-show_chapters", t.url.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let format = json["format"] as? [String: Any] ?? [:]
        if let d = Double(format["duration"] as? String ?? "") { t.duration = d }
        if let br = Double(format["bit_rate"] as? String ?? "") { t.bitrateKbps = Int(br / 1000) }
        var tags: [String: String] = [:]
        for (k, v) in format["tags"] as? [String: String] ?? [:] { tags[k.uppercased()] = v }

        let streams = json["streams"] as? [[String: Any]] ?? []
        if let a = streams.first(where: { $0["codec_type"] as? String == "audio" }) {
            t.sampleRate = Double(a["sample_rate"] as? String ?? "") ?? 0
            t.channels = a["channels"] as? Int ?? 0
            t.codec = (a["codec_name"] as? String ?? t.ext).uppercased()
            t.bitsPerSample = Int(a["bits_per_raw_sample"] as? String ?? "") ?? (a["bits_per_sample"] as? Int ?? 0)
            for (k, v) in a["tags"] as? [String: String] ?? [:] where tags[k.uppercased()] == nil {
                tags[k.uppercased()] = v
            }
        }
        MetadataLoader.apply(tags, to: &t)

        let chapters = json["chapters"] as? [[String: Any]] ?? []
        t.chapters = chapters.enumerated().map { i, c in
            let start = Double(c["start_time"] as? String ?? "") ?? 0
            let end = Double(c["end_time"] as? String ?? "") ?? start
            let title = (c["tags"] as? [String: String])?["title"] ?? "Chapter \(i + 1)"
            return Chapter(index: i, title: title, start: start, duration: end - start)
        }
    }
}
#endif
