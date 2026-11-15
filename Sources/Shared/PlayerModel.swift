import Foundation
import MediaPlayer
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class PlayerModel {
    static let shared = PlayerModel()

    enum RepeatMode: Int { case off, all, one }

    struct EQPreset: Identifiable {
        let name: String
        let gains: [Double]
        var id: String { name }
    }

    static let eqPresets: [EQPreset] = [
        .init(name: "Flat", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        .init(name: "Rock", gains: [5, 3, -3, -5, -2, 2, 6, 7, 7, 7]),
        .init(name: "Pop", gains: [-1, 3, 5, 5, 3, 0, -1, -1, -1, -1]),
        .init(name: "Jazz", gains: [3, 2, 0, 2, -2, -2, 0, 2, 3, 4]),
        .init(name: "Classical", gains: [0, 0, 0, 0, 0, 0, -5, -5, -5, -7]),
        .init(name: "Dance", gains: [7, 5, 2, 0, 0, -4, -5, -5, 0, 0]),
        .init(name: "Club", gains: [0, 0, 5, 3, 3, 3, 2, 0, 0, 0]),
        .init(name: "Live", gains: [-3, 0, 3, 4, 4, 4, 3, 2, 2, 2]),
        .init(name: "Full Bass", gains: [8, 8, 8, 5, 1, -4, -8, -9, -9, -9]),
        .init(name: "Full Treble", gains: [-9, -9, -9, -4, 2, 8, 11, 11, 11, 12]),
        .init(name: "Bass & Treble", gains: [6, 5, 0, -6, -4, 1, 6, 9, 9, 9]),
        .init(name: "Headphones", gains: [4, 9, 4, -3, -2, 1, 4, 8, 10, 11]),
        .init(name: "Spoken Word", gains: [-4, -2, 0, 3, 5, 5, 4, 2, 0, -2]),
        .init(name: "Soft", gains: [4, 1, 0, -2, 0, 4, 7, 9, 9, 10]),
    ]

    static let speeds: [Double] = [0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    // MARK: State

    var tracks: [Track] = [] { didSet { schedulePlaylistSave() } }
    var selection: Set<Track.ID> = []
    private(set) var currentID: Track.ID?
    private(set) var isPlaying = false
    private(set) var isPaused = false
    private(set) var isLoading = false
    var position: Double = 0
    private(set) var duration: Double = 0
    var message: String?
    var showRemaining = false

    var volume: Double = 0.8 { didSet { engine.volume = Float(volume); save("volume", volume); updateNowPlaying() } }
    var balance: Double = 0 { didSet { engine.balance = Float(balance); save("balance", balance) } }
    var rate: Double = 1 { didSet { engine.rate = Float(rate); save("rate", rate); updateNowPlaying() } }
    var shuffle = false { didSet { save("shuffle", shuffle) } }
    var repeatMode: RepeatMode = .all { didSet { save("repeat", repeatMode.rawValue) } }
    var eqEnabled = true { didSet { engine.eqEnabled = eqEnabled; save("eqEnabled", eqEnabled) } }
    var preamp: Double = 0 { didSet { engine.preamp = Float(preamp); save("preamp", preamp) } }
    var eqGains = [Double](repeating: 0, count: 10) {
        didSet {
            for (i, g) in eqGains.enumerated() { engine.setGain(Float(g), band: i) }
            save("eqGains", eqGains)
        }
    }
    var showEqualizer = true { didSet { save("showEQ", showEqualizer) } }
    var showPlaylist = true { didSet { save("showPL", showPlaylist) } }

    let visualizer = VisualizerState()

    @ObservationIgnored private let engine = AudioEngine()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var loadToken = 0
    @ObservationIgnored private var history: [Track.ID] = []
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var lastResumeSave = Date.distantPast
    @ObservationIgnored private var resumePositions: [String: Double] =
        UserDefaults.standard.dictionary(forKey: "resumePositions") as? [String: Double] ?? [:]
    /// When each position last changed (epoch seconds), so Mac ↔ iPhone sync keeps the newest.
    @ObservationIgnored private var resumeStamps: [String: Double] =
        UserDefaults.standard.dictionary(forKey: "resumeStamps") as? [String: Double] ?? [:]

    var currentTrack: Track? { tracks.first { $0.id == currentID } }
    var currentIndex: Int? { tracks.firstIndex { $0.id == currentID } }
    var currentChapterIndex: Int? { currentTrack?.chapterIndex(at: position) }
    var totalDuration: Double { tracks.reduce(0) { $0 + $1.duration } }

    private init() {
        let d = UserDefaults.standard
        if d.object(forKey: "volume") != nil { volume = d.double(forKey: "volume") }
        balance = d.double(forKey: "balance")
        if d.object(forKey: "rate") != nil { rate = d.double(forKey: "rate") }
        shuffle = d.bool(forKey: "shuffle")
        if d.object(forKey: "repeat") != nil { repeatMode = RepeatMode(rawValue: d.integer(forKey: "repeat")) ?? .all }
        if d.object(forKey: "eqEnabled") != nil { eqEnabled = d.bool(forKey: "eqEnabled") }
        preamp = d.double(forKey: "preamp")
        if let g = d.array(forKey: "eqGains") as? [Double], g.count == 10 { eqGains = g }
        if d.object(forKey: "showEQ") != nil { showEqualizer = d.bool(forKey: "showEQ") }
        if d.object(forKey: "showPL") != nil { showPlaylist = d.bool(forKey: "showPL") }

        engine.volume = Float(volume)
        engine.balance = Float(balance)
        engine.rate = Float(rate)
        engine.eqEnabled = eqEnabled
        engine.preamp = Float(preamp)
        for (i, g) in eqGains.enumerated() { engine.setGain(Float(g), band: i) }

        engine.onFinished = { [weak self] in self?.trackFinished() }
        engine.onVisual = { [weak self] bars, wave in self?.visualizer.update(bars: bars, wave: wave) }

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)

        setupRemoteCommands()
        restorePlaylist()
        #if os(macOS)
        FFmpegDecoder.pruneCache()
        #endif
    }

    private func save(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: key) }

    private func tick() {
        guard isPlaying else {
            if visualizer.bars.contains(where: { $0 > 0 }) { visualizer.decay() }
            return
        }
        position = engine.currentTime
        if Date().timeIntervalSince(lastResumeSave) > 5 { saveResumePosition() }
    }

    // MARK: Transport

    func play(_ id: Track.ID) {
        Task { await start(id) }
    }

    private func start(_ id: Track.ID, resume: Bool = true) async {
        guard let track = tracks.first(where: { $0.id == id }) else { return }
        saveResumePosition()
        if let cur = currentID, cur != id { history.append(cur) }
        currentID = id
        loadToken += 1
        let token = loadToken
        message = nil
        isLoading = true
        defer { if token == loadToken { isLoading = false } }

        var url = track.url
        #if os(macOS)
        if !AudioFormats.isNative(track.ext) {
            message = "Decoding \(track.ext.uppercased())…"
            do { url = try await FFmpegDecoder.decode(track.url) } catch {
                guard token == loadToken else { return }
                fail(track, error)
                return
            }
            guard token == loadToken else { return }
            message = nil
        }
        #endif

        do { try engine.load(url: url) } catch {
            fail(track, error)
            return
        }
        duration = engine.duration
        position = 0
        if resume, track.remembersPosition, let saved = resumePositions[track.positionKey], saved < duration - 5 {
            engine.seek(to: saved)
            position = saved
        }
        engine.play()
        isPlaying = true
        isPaused = false
        if !track.metadataLoaded { Task { await refreshMetadata(for: [track]) } }
        updateNowPlaying()
    }

    private func fail(_ track: Track, _ error: Error) {
        isPlaying = false
        isPaused = false
        message = "Can't play \(track.url.lastPathComponent): \(error.localizedDescription)"
        updateNowPlaying()
    }

    /// Winamp "Play" (X): resume if paused, restart if playing, otherwise start the selection.
    func playPressed() {
        if isPaused { togglePause(); return }
        if isPlaying { seek(to: 0); return }
        if currentID != nil, engine.duration > 0, !isLoading {
            engine.play()
            isPlaying = true
            isPaused = false
            updateNowPlaying()
            return
        }
        if let id = currentID ?? tracks.first(where: { selection.contains($0.id) })?.id ?? tracks.first?.id {
            play(id)
        }
    }

    func togglePause() {
        if isPlaying {
            engine.pause()
            position = engine.currentTime
            isPlaying = false
            isPaused = true
            saveResumePosition()
        } else if isPaused {
            engine.play()
            isPlaying = true
            isPaused = false
        } else {
            playPressed()
        }
        updateNowPlaying()
    }

    func stop() {
        saveResumePosition()
        engine.stop()
        isPlaying = false
        isPaused = false
        position = 0
        updateNowPlaying()
    }

    func next() { advance(by: 1, auto: false) }

    func previous() {
        if position > 3, !shuffle { seek(to: 0); return }
        if shuffle, let last = history.popLast() {
            currentID = nil  // don't push onto history again
            play(last)
            return
        }
        advance(by: -1, auto: false)
    }

    private func advance(by delta: Int, auto: Bool) {
        guard !tracks.isEmpty else { return }
        if shuffle, tracks.count > 1 {
            let candidates = tracks.filter { $0.id != currentID }
            if let pick = candidates.randomElement() { play(pick.id) }
            return
        }
        let idx = currentIndex ?? (delta > 0 ? -1 : tracks.count)
        var nextIdx = idx + delta
        if nextIdx >= tracks.count || nextIdx < 0 {
            guard repeatMode != .off || !auto else { stop(); return }
            nextIdx = (nextIdx + tracks.count) % tracks.count
        }
        play(tracks[nextIdx].id)
    }

    private func trackFinished() {
        if let t = currentTrack, t.remembersPosition { setResume(nil, for: t.positionKey) }
        isPlaying = false
        if repeatMode == .one, let id = currentID {
            Task { await start(id, resume: false) }
        } else {
            advance(by: 1, auto: true)
        }
    }

    func seek(to seconds: Double) {
        guard currentID != nil else { return }
        engine.seek(to: seconds)
        position = max(0, min(seconds, duration))
        updateNowPlaying()
    }

    func skip(_ seconds: Double) { seek(to: position + seconds) }

    func nextChapter() {
        guard let t = currentTrack, let i = currentChapterIndex else { next(); return }
        if i + 1 < t.chapters.count { seek(to: t.chapters[i + 1].start) } else { next() }
    }

    func previousChapter() {
        guard let t = currentTrack, let i = currentChapterIndex else { previous(); return }
        if position - t.chapters[i].start > 3 || i == 0 {
            seek(to: t.chapters[i].start)
        } else {
            seek(to: t.chapters[i - 1].start)
        }
    }

    func cycleRepeat() { repeatMode = RepeatMode(rawValue: (repeatMode.rawValue + 1) % 3) ?? .off }

    func applyPreset(_ p: EQPreset) { eqGains = p.gains }

    // MARK: Resume positions (audiobooks)

    private func saveResumePosition() {
        lastResumeSave = Date()
        guard let t = currentTrack, t.remembersPosition, duration > 0 else { return }
        let pos = engine.currentTime
        setResume(pos > 5 && pos < duration - 5 ? pos : nil, for: t.positionKey)
    }

    private func setResume(_ seconds: Double?, for key: String, stamp: Double = Date().timeIntervalSince1970) {
        guard resumePositions[key] != seconds || resumeStamps[key] == nil else { return }
        resumePositions[key] = seconds
        resumeStamps[key] = stamp
        UserDefaults.standard.set(resumePositions, forKey: "resumePositions")
        UserDefaults.standard.set(resumeStamps, forKey: "resumeStamps")
    }

    /// Positions for sync, keyed by `Track.positionKey`. 0 seconds means "finished / start over".
    func resumeSnapshot() -> [String: SyncPosition] {
        saveResumePosition()
        var out: [String: SyncPosition] = [:]
        for (key, stamp) in resumeStamps {
            out[key] = SyncPosition(seconds: resumePositions[key] ?? 0, updated: stamp)
        }
        return out
    }

    /// Adopt positions that are newer than ours.
    func mergeResume(_ incoming: [String: SyncPosition]) {
        for (key, p) in incoming where p.updated > (resumeStamps[key] ?? 0) {
            // Don't yank the track that's playing right now.
            if isPlaying, currentTrack?.positionKey == key { continue }
            setResume(p.seconds > 0 ? p.seconds : nil, for: key, stamp: p.updated)
            if let t = currentTrack, t.positionKey == key, !isPlaying {
                if engine.duration > 0 { engine.seek(to: p.seconds) }
                position = p.seconds
            }
        }
    }

    func applicationWillTerminate() {
        saveResumePosition()
        savePlaylistNow()
    }

    // MARK: Playlist editing

    func add(urls: [URL], playFirst: Bool = false) {
        let files = Self.expand(urls)
        guard !files.isEmpty else {
            if !urls.isEmpty { message = "No playable audio found." }
            return
        }
        let newTracks = files.map(Track.init(url:))
        tracks.append(contentsOf: newTracks)
        if playFirst, let first = newTracks.first { play(first.id) }
        Task { await refreshMetadata(for: newTracks) }
    }

    func remove(_ ids: Set<Track.ID>) {
        if let id = currentID, ids.contains(id) { stop(); currentID = nil; duration = 0 }
        #if os(iOS)
        // On iPhone the playlist *is* the library: removing a track deletes its file.
        for t in tracks where ids.contains(t.id) && Self.isInLibrary(t.url) {
            try? FileManager.default.removeItem(at: t.url)
        }
        #endif
        tracks.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    func crop(to ids: Set<Track.ID>) { remove(Set(tracks.map(\.id)).subtracting(ids)) }

    func clear() {
        stop()
        tracks.removeAll()
        selection.removeAll()
        currentID = nil
        duration = 0
        updateNowPlaying()
    }

    func move(from source: IndexSet, to destination: Int) {
        tracks.move(fromOffsets: source, toOffset: destination)
    }

    enum SortKey { case title, artist, album, path, duration, random }

    func sort(by key: SortKey) {
        switch key {
        case .title: tracks.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist: tracks.sort { ($0.artist ?? "", $0.album ?? "", $0.url.path) < ($1.artist ?? "", $1.album ?? "", $1.url.path) }
        case .album: tracks.sort { ($0.album ?? "", $0.url.path) < ($1.album ?? "", $1.url.path) }
        case .path: tracks.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        case .duration: tracks.sort { $0.duration < $1.duration }
        case .random: tracks.shuffle()
        }
    }

    private func refreshMetadata(for list: [Track]) async {
        await withTaskGroup(of: Track.self) { group in
            var iterator = list.makeIterator()
            for _ in 0..<6 {
                guard let t = iterator.next() else { break }
                group.addTask { await MetadataLoader.load(t) }
            }
            for await loaded in group {
                if let i = tracks.firstIndex(where: { $0.id == loaded.id }) { tracks[i] = loaded }
                if loaded.id == currentID { updateNowPlaying() }
                if let t = iterator.next() { group.addTask { await MetadataLoader.load(t) } }
            }
        }
    }

    static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let items = fm.enumerator(at: url, includingPropertiesForKeys: nil,
                                          options: [.skipsHiddenFiles, .skipsPackageDescendants])?
                    .compactMap { $0 as? URL } ?? []
                out += items
                    .filter { AudioFormats.playable.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else if AudioFormats.playlists.contains(url.pathExtension.lowercased()) {
                out += expand(Playlist.read(url))
            } else if AudioFormats.playable.contains(url.pathExtension.lowercased()) {
                out.append(url)
            }
        }
        return out
    }

    // MARK: Persistence

    private static var stateURL: URL {
        // SINGER_STATE_DIR keeps test runs away from the real playlist.
        let dir = ProcessInfo.processInfo.environment["SINGER_STATE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Singer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("playlist.json")
    }

    private struct SavedState: Codable {
        var tracks: [Track]
        var currentPath: String?
    }

    private func schedulePlaylistSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.savePlaylistNow() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Where the iPhone keeps its music (Documents, visible in Files and Finder). nil on the Mac.
    static var libraryDirectory: URL? {
        #if os(iOS)
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #else
        nil
        #endif
    }

    static func isInLibrary(_ url: URL) -> Bool {
        guard let lib = libraryDirectory else { return false }
        return url.standardizedFileURL.path.hasPrefix(lib.standardizedFileURL.path)
    }

    /// Add synced/imported tracks whose metadata is already known.
    func addPrepared(_ new: [Track]) {
        let known = Set(tracks.compactMap(\.syncID))
        tracks.append(contentsOf: new.filter { $0.syncID == nil || !known.contains($0.syncID!) })
    }

    func savePlaylistNow() {
        let state = SavedState(tracks: tracks, currentPath: currentTrack?.url.path)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: Self.stateURL, options: .atomic) }
    }

    private func restorePlaylist() {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        tracks = state.tracks.compactMap { t in
            if FileManager.default.fileExists(atPath: t.url.path) { return t }
            // iOS moves the app container on updates; find the file again by name in the library.
            guard let lib = Self.libraryDirectory else { return nil }
            var moved = t
            moved.url = lib.appendingPathComponent(t.url.lastPathComponent)
            return FileManager.default.fileExists(atPath: moved.url.path) ? moved : nil
        }
        if let path = state.currentPath {
            let name = URL(fileURLWithPath: path).lastPathComponent
            currentID = (tracks.first { $0.url.path == path } ?? tracks.first { $0.url.lastPathComponent == name })?.id
        }
        if let t = currentTrack {
            duration = t.duration
            if t.remembersPosition { position = resumePositions[t.positionKey] ?? 0 }
        }
    }

    // MARK: Media keys & Now Playing

    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        func on(_ cmd: MPRemoteCommand, _ action: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
            cmd.isEnabled = true
            cmd.addTarget { event in
                Task { @MainActor in action(event) }
                return .success
            }
        }
        on(cc.playCommand) { [weak self] _ in if self?.isPlaying == false { self?.togglePause() } }
        on(cc.pauseCommand) { [weak self] _ in if self?.isPlaying == true { self?.togglePause() } }
        on(cc.togglePlayPauseCommand) { [weak self] _ in self?.togglePause() }
        on(cc.stopCommand) { [weak self] _ in self?.stop() }
        on(cc.nextTrackCommand) { [weak self] _ in self?.next() }
        on(cc.previousTrackCommand) { [weak self] _ in self?.previous() }
        on(cc.changePlaybackPositionCommand) { [weak self] e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { self?.seek(to: e.positionTime) }
        }
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let t = currentTrack else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let a = t.artist { info[MPMediaItemPropertyArtist] = a }
        if let a = t.album { info[MPMediaItemPropertyAlbumTitle] = a }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : (isPaused ? .paused : .stopped)
    }
}

enum Playlist {
    static func read(_ url: URL) -> [URL] {
        guard let text = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { return [] }
        let base = url.deletingLastPathComponent()
        return text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            if let u = URL(string: line), u.isFileURL { return u }
            return line.hasPrefix("/") ? URL(fileURLWithPath: line)
                                       : base.appendingPathComponent(line).standardizedFileURL
        }
    }

    static func write(_ tracks: [Track], to url: URL) throws {
        var lines = ["#EXTM3U"]
        for t in tracks {
            lines.append("#EXTINF:\(Int(t.duration)),\(t.displayTitle)")
            lines.append(t.url.path)
        }
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
