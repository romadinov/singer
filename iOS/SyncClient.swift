import Foundation
import Network
import Observation

/// Finds Singer on Macs over Bonjour, downloads tracks and syncs audiobook positions.
@MainActor @Observable
final class SyncClient {
    static let shared = SyncClient()

    struct Peer: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    enum State: Equatable {
        case idle
        case connecting
        case needsPIN
        case connected
        case failed(String)
    }

    private(set) var peers: [Peer] = []
    private(set) var state: State = .idle
    private(set) var peer: Peer?
    private(set) var remote: SyncLibrary?
    private(set) var downloading: Set<String> = []
    private(set) var queued: [String] = []
    private(set) var progress: [String: Double] = [:]
    private(set) var lastSync: Date?
    var error: String?

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var baseURL: URL?
    @ObservationIgnored private let downloader = Downloader()
    @ObservationIgnored private var queueTask: Task<Void, Never>?

    private init() {}

    // MARK: Discovery

    func startBrowsing() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: SyncProtocol.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { r -> Peer? in
                if case let .service(name, _, _, _) = r.endpoint { return Peer(name: name, endpoint: r.endpoint) }
                return nil
            }
            Task { @MainActor in
                self?.peers = found.sorted { $0.name < $1.name }
                // Test hook: `-autoSyncPIN 123456` connects to the first Mac and downloads everything.
                if let self, self.peer == nil, self.state == .idle,
                   let pin = UserDefaults.standard.string(forKey: "autoSyncPIN"), let p = found.first {
                    self.connect(p, pin: pin)
                    return
                }
                // Reconnect automatically to the Mac we used last time.
                if let self, self.peer == nil, self.state == .idle,
                   let last = UserDefaults.standard.string(forKey: "syncLastPeer"),
                   let p = found.first(where: { $0.name == last }) {
                    self.connect(p)
                }
            }
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state {
                Task { @MainActor in self?.error = "Can't search the network: \(e.localizedDescription)" }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    // MARK: Connection

    private func pinKey(_ peer: Peer) -> String { "syncPIN." + peer.name }

    func connect(_ peer: Peer, pin: String? = nil) {
        if let pin { UserDefaults.standard.set(pin, forKey: pinKey(peer)) }
        self.peer = peer
        state = .connecting
        error = nil
        Task {
            do {
                baseURL = try await Self.resolve(peer.endpoint)
                try await refresh()
                UserDefaults.standard.set(peer.name, forKey: "syncLastPeer")
            } catch SyncError.unauthorized {
                state = .needsPIN
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        queueTask?.cancel()
        queued.removeAll()
        peer = nil
        remote = nil
        baseURL = nil
        state = .idle
        UserDefaults.standard.removeObject(forKey: "syncLastPeer")
    }

    func refresh() async throws {
        let data = try await request("/library")
        let lib = try JSONDecoder().decode(SyncLibrary.self, from: data)
        remote = lib
        state = .connected
        PlayerModel.shared.mergeResume(lib.positions)
        try? await syncPositions()
        if UserDefaults.standard.string(forKey: "autoSyncPIN") != nil { downloadAll() }
    }

    func syncPositions() async throws {
        let local = PlayerModel.shared.resumeSnapshot().filter { key, _ in
            PlayerModel.shared.tracks.contains { $0.syncID == key }
        }
        let body = try JSONEncoder().encode(local)
        let data = try await request("/positions", method: "POST", body: body)
        let merged = try JSONDecoder().decode([String: SyncPosition].self, from: data)
        PlayerModel.shared.mergeResume(merged)
        lastSync = Date()
    }

    // MARK: Downloads

    func isLocal(_ syncID: String?) -> Bool {
        guard let syncID else { return false }
        return PlayerModel.shared.tracks.contains { $0.syncID == syncID }
    }

    var missingCount: Int { remote?.tracks.filter { !isLocal($0.syncID) }.count ?? 0 }

    func download(_ ids: [String]) {
        let new = ids.filter { !isLocal($0) && !queued.contains($0) && !downloading.contains($0) }
        queued.append(contentsOf: new)
        guard queueTask == nil else { return }
        queueTask = Task {
            while !queued.isEmpty, !Task.isCancelled {
                let id = queued.removeFirst()
                await downloadOne(id)
            }
            queueTask = nil
            try? await syncPositions()
        }
    }

    func downloadAll() { download(remote?.tracks.compactMap(\.syncID) ?? []) }

    func cancelDownloads() {
        queued.removeAll()
        queueTask?.cancel()
        downloader.cancelAll()
    }

    private func downloadOne(_ id: String) async {
        guard let base = baseURL, let remoteTrack = remote?.tracks.first(where: { $0.syncID == id }),
              let lib = PlayerModel.libraryDirectory else { return }
        downloading.insert(id)
        progress[id] = 0
        defer { downloading.remove(id); progress[id] = nil }

        var req = URLRequest(url: base.appendingPathComponent("track/\(id)"))
        req.setValue(currentPIN, forHTTPHeaderField: SyncProtocol.pinHeader)
        req.timeoutInterval = 120
        do {
            let (tmp, response) = try await downloader.download(req) { [weak self] p in
                Task { @MainActor in self?.progress[id] = p }
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw SyncError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            let ext = http.value(forHTTPHeaderField: SyncProtocol.extHeader) ?? remoteTrack.ext
            let dest = Self.uniqueURL(in: lib, base: Self.fileName(for: remoteTrack), ext: ext)
            try FileManager.default.moveItem(at: tmp, to: dest)

            var t = remoteTrack
            t.id = UUID()
            t.url = dest
            t.metadataLoaded = true
            MetadataLoader.readTechnicalInfo(into: &t)
            PlayerModel.shared.addPrepared([t])
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            self.error = "“\(remoteTrack.displayTitle)”: \(error.localizedDescription)"
        }
    }

    private var currentPIN: String {
        peer.flatMap { UserDefaults.standard.string(forKey: pinKey($0)) } ?? ""
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard let base = baseURL else { throw SyncError.notConnected }
        var req = URLRequest(url: base.appendingPathComponent(String(path.dropFirst())))
        req.httpMethod = method
        req.httpBody = body
        req.timeoutInterval = 15
        req.setValue(currentPIN, forHTTPHeaderField: SyncProtocol.pinHeader)
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw SyncError.unauthorized }
        guard code == 200 else { throw SyncError.http(code) }
        return data
    }

    // MARK: Helpers

    enum SyncError: LocalizedError {
        case unauthorized, notConnected, http(Int), unresolved
        var errorDescription: String? {
            switch self {
            case .unauthorized: "Wrong PIN"
            case .notConnected: "Not connected"
            case .http(let c): "The Mac answered with HTTP \(c)"
            case .unresolved: "Couldn't reach the Mac — is Singer open with iPhone Sync turned on?"
            }
        }
    }

    /// Bonjour service → http://ip:port (IPv4 avoids link-local zone-ID headaches in URLs).
    private static func resolve(_ endpoint: NWEndpoint) async throws -> URL {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let conn = NWConnection(to: endpoint, using: params)
        return try await withCheckedThrowingContinuation { cont in
            // All callbacks run on the main queue, so a plain flag is enough to resume once.
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            let finish: @Sendable (Result<URL, Error>) -> Void = { r in
                guard !once.done else { return }
                once.done = true
                conn.cancel()
                cont.resume(with: r)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = conn.currentPath?.remoteEndpoint {
                        var h = "\(host)"
                        if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
                        if h.contains(":") { h = "[\(h)]" }
                        if let url = URL(string: "http://\(h):\(port.rawValue)/") { finish(.success(url)); return }
                    }
                    finish(.failure(SyncError.unresolved))
                case .failed, .cancelled:
                    finish(.failure(SyncError.unresolved))
                default: break
                }
            }
            conn.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish(.failure(SyncError.unresolved)) }
        }
    }

    private static func fileName(for t: Track) -> String {
        let raw = t.artist.map { "\($0) - \(t.title)" } ?? t.title
        let cleaned = raw.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "_")
        return String(cleaned.prefix(120)).trimmingCharacters(in: .whitespaces)
    }

    static func uniqueURL(in dir: URL, base: String, ext: String) -> URL {
        var url = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }
}

/// URLSession download with byte progress; one task at a time.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var handlers: [Int: (progress: (Double) -> Void,
                                 done: CheckedContinuation<(URL, URLResponse), Error>)] = [:]
    private let lock = NSLock()

    func download(_ req: URLRequest, progress: @escaping (Double) -> Void) async throws -> (URL, URLResponse) {
        let task = session.downloadTask(with: req)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                lock.withLock { handlers[task.taskIdentifier] = (progress, cont) }
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    func cancelAll() { session.getAllTasks { $0.forEach { $0.cancel() } } }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let h = lock.withLock { handlers[downloadTask.taskIdentifier] }
        h?.progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this returns, so move it somewhere we own first.
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let h = lock.withLock { handlers.removeValue(forKey: downloadTask.taskIdentifier) }
        do {
            try FileManager.default.moveItem(at: location, to: keep)
            h?.done.resume(returning: (keep, downloadTask.response!))
        } catch {
            h?.done.resume(throwing: error)
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let h = lock.withLock { handlers.removeValue(forKey: task.taskIdentifier) }
        h?.done.resume(throwing: error)
    }
}
