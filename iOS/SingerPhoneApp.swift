import AVFoundation
import SwiftUI

@main
struct SingerPhoneApp: App {
    @State private var model = PlayerModel.shared
    @State private var sync = SyncClient.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        AudioSessionObserver.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            PhoneRootView()
                .environment(model)
                .environment(sync)
                .preferredColorScheme(.dark)
                .onOpenURL { url in PhoneLibrary.importFiles([url]) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                PhoneLibrary.scanDocuments()
                sync.startBrowsing()
            case .background:
                model.applicationWillTerminate()
                if sync.downloading.isEmpty { sync.stopBrowsing() }
            default: break
            }
        }
    }
}

/// Phone calls, Siri and unplugged headphones pause playback, like every iOS player.
@MainActor
final class AudioSessionObserver {
    static let shared = AudioSessionObserver()
    private var resumeAfterInterruption = false

    func start() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let info = note.userInfo ?? [:]
            let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let opts = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated {
                let model = PlayerModel.shared
                if type == .began {
                    self.resumeAfterInterruption = model.isPlaying
                    if model.isPlaying { model.togglePause() }
                } else if type == .ended, opts.contains(.shouldResume), self.resumeAfterInterruption {
                    model.togglePause()
                }
            }
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                if reason == .oldDeviceUnavailable, PlayerModel.shared.isPlaying { PlayerModel.shared.togglePause() }
            }
        }
    }
}

/// The iPhone library is the app's Documents folder (visible in Files and in Finder's file sharing).
@MainActor
enum PhoneLibrary {
    /// Pick up files dropped in via Finder or the Files app.
    static func scanDocuments() {
        guard let lib = PlayerModel.libraryDirectory else { return }
        let model = PlayerModel.shared
        let known = Set(model.tracks.map { $0.url.standardizedFileURL.path })
        let found = PlayerModel.expand([lib]).filter { !known.contains($0.standardizedFileURL.path) }
        guard !found.isEmpty else { return }
        model.add(urls: found)
        tagNewTracks(found)
    }

    /// Copy files picked in the Files app into the library.
    static func importFiles(_ urls: [URL]) {
        guard let lib = PlayerModel.libraryDirectory else { return }
        var copied: [URL] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if PlayerModel.isInLibrary(url) { copied.append(url); continue }
            let dest = SyncClient.uniqueURL(in: lib, base: url.deletingPathExtension().lastPathComponent,
                                            ext: url.pathExtension)
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                copied.append(dest)
            } catch {
                PlayerModel.shared.message = "Import failed: \(error.localizedDescription)"
            }
        }
        PlayerModel.shared.add(urls: copied, playFirst: !PlayerModel.shared.isPlaying)
        tagNewTracks(copied)
    }

    /// Local files get their own sync identity so positions survive app updates.
    private static func tagNewTracks(_ urls: [URL]) {
        let paths = Set(urls.map(\.standardizedFileURL.path))
        let model = PlayerModel.shared
        for i in model.tracks.indices where model.tracks[i].syncID == nil
            && paths.contains(model.tracks[i].url.standardizedFileURL.path) {
            model.tracks[i].syncID = "local-" + UUID().uuidString
        }
    }
}
