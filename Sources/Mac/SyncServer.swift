import Foundation
import Network
import Observation

/// Shares the Mac playlist with Singer on iPhone over the local network.
/// Advertised over Bonjour; every request except /hello needs the PIN shown in the Sync window.
@MainActor @Observable
final class SyncServer {
    static let shared = SyncServer()

    var enabled = UserDefaults.standard.bool(forKey: "syncEnabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "syncEnabled")
            enabled ? start() : stop()
        }
    }
    private(set) var pin: String
    private(set) var status = "Off"
    private(set) var activity: String?

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private let queue = DispatchQueue(label: "singer.sync")

    let name = Host.current().localizedName ?? "Mac"

    private init() {
        if let saved = UserDefaults.standard.string(forKey: "syncPIN") {
            pin = saved
        } else {
            pin = Self.newPIN()
            UserDefaults.standard.set(pin, forKey: "syncPIN")
        }
        if enabled { start() }
    }

    private static func newPIN() -> String { String(format: "%06d", Int.random(in: 0..<1_000_000)) }

    func regeneratePIN() {
        pin = Self.newPIN()
        UserDefaults.standard.set(pin, forKey: "syncPIN")
    }

    private func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let l = try NWListener(using: params)
            l.service = NWListener.Service(name: name, type: SyncProtocol.serviceType)
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.status = "Waiting for iPhone (port \(l.port?.rawValue ?? 0))"
                    case .failed(let e): self?.status = "Failed: \(e.localizedDescription)"; self?.listener = nil
                    default: break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                HTTPConnection(connection: conn, queue: self.queue) { req in
                    await self.handle(req)
                }.start()
            }
            l.start(queue: queue)
            listener = l
            status = "Starting…"
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        status = "Off"
    }

    // MARK: Routes

    private func handle(_ req: HTTPRequest) async -> HTTPResponse {
        let model = PlayerModel.shared
        if req.method == "GET", req.path == "/hello" {
            return .json(SyncHello(name: name, trackCount: model.tracks.count))
        }
        guard req.headers[SyncProtocol.pinHeader.lowercased()] == pin else {
            return HTTPResponse(status: 401, body: Data("Wrong PIN".utf8))
        }

        switch (req.method, req.path) {
        case ("GET", "/library"):
            activity = "iPhone browsed the library"
            return .json(SyncLibrary(name: name, tracks: model.tracks.map(Self.wireTrack),
                                     positions: positionsByID()))

        case ("POST", "/positions"):
            if let incoming = try? JSONDecoder().decode([String: SyncPosition].self, from: req.body) {
                let pathByID = Dictionary(model.tracks.map { (SyncProtocol.syncID(forPath: $0.url.path), $0.positionKey) },
                                          uniquingKeysWith: { a, _ in a })
                var mapped: [String: SyncPosition] = [:]
                for (id, p) in incoming { if let key = pathByID[id] { mapped[key] = p } }
                model.mergeResume(mapped)
            }
            return .json(positionsByID())

        case ("GET", let path) where path.hasPrefix("/track/"):
            let id = String(path.dropFirst("/track/".count))
            guard let track = model.tracks.first(where: { SyncProtocol.syncID(forPath: $0.url.path) == id }) else {
                return HTTPResponse(status: 404, body: Data("Unknown track".utf8))
            }
            activity = "Sending “\(track.displayTitle)”"
            do {
                var url = track.url
                if !AudioFormats.isNative(track.ext) { url = try await FFmpegDecoder.decode(url) }
                return HTTPResponse(status: 200, headers: [SyncProtocol.extHeader: url.pathExtension],
                                    file: url)
            } catch {
                return HTTPResponse(status: 500, body: Data(error.localizedDescription.utf8))
            }

        default:
            return HTTPResponse(status: 404, body: Data("Not found".utf8))
        }
    }

    private func positionsByID() -> [String: SyncPosition] {
        let snapshot = PlayerModel.shared.resumeSnapshot()
        var out: [String: SyncPosition] = [:]
        for t in PlayerModel.shared.tracks {
            if let p = snapshot[t.positionKey] { out[SyncProtocol.syncID(forPath: t.url.path)] = p }
        }
        return out
    }

    /// The track as the iPhone will receive it: syncID set, extension = served format.
    private static func wireTrack(_ t: Track) -> Track {
        var w = t
        w.syncID = SyncProtocol.syncID(forPath: t.url.path)
        if !AudioFormats.isNative(t.ext) {
            let ext = FFmpegDecoder.outputExtension(for: t.ext)
            w.url = t.url.deletingPathExtension().appendingPathExtension(ext)
            w.codec = ext == "flac" ? "FLAC" : "PCM"
        }
        return w
    }
}

// MARK: - Minimal HTTP/1.1 over NWConnection

struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}

struct HTTPResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()
    var file: URL?

    init(status: Int, headers: [String: String] = [:], body: Data = Data(), file: URL? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.file = file
    }

    static func json<T: Encodable>(_ value: T) -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["Content-Type": "application/json"],
                     body: (try? JSONEncoder().encode(value)) ?? Data())
    }
}

final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private var buffer = Data()

    init(connection: NWConnection, queue: DispatchQueue,
         handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
    }

    func start() {
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, error in
            if let data { buffer.append(data) }
            if let req = parse() {
                Task {
                    let resp = await handler(req)
                    queue.async { self.send(resp) }
                }
            } else if done || error != nil || buffer.count > 4_000_000 {
                connection.cancel()
            } else {
                receive()
            }
        }
    }

    private func parse() -> HTTPRequest? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard buffer.count - bodyStart >= length else { return nil }
        let path = String(parts[1]).components(separatedBy: "?")[0]
        return HTTPRequest(method: String(parts[0]), path: path, headers: headers,
                           body: buffer.subdata(in: bodyStart..<bodyStart + length))
    }

    private func send(_ resp: HTTPResponse) {
        var headers = resp.headers
        var fileHandle: FileHandle?
        var length = resp.body.count
        if let file = resp.file, let fh = try? FileHandle(forReadingFrom: file),
           let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int {
            fileHandle = fh
            length = size
            headers["Content-Type"] = "application/octet-stream"
        }
        headers["Content-Length"] = "\(length)"
        headers["Connection"] = "close"
        let reason = [200: "OK", 401: "Unauthorized", 404: "Not Found"][resp.status] ?? "Error"
        var head = "HTTP/1.1 \(resp.status) \(reason)\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"

        connection.send(content: Data(head.utf8) + (fileHandle == nil ? resp.body : Data()),
                        completion: .contentProcessed { [self] error in
            guard error == nil, let fh = fileHandle else { finish(); return }
            sendChunks(fh)
        })
    }

    private func sendChunks(_ fh: FileHandle) {
        let chunk = (try? fh.read(upToCount: 1 << 20)) ?? Data()
        guard !chunk.isEmpty else { try? fh.close(); finish(); return }
        connection.send(content: chunk, completion: .contentProcessed { [self] error in
            if error != nil { try? fh.close(); connection.cancel(); return }
            sendChunks(fh)
        })
    }

    private func finish() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [connection] _ in connection.cancel() })
    }
}
