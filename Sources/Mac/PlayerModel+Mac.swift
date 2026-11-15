import AppKit
import UniformTypeIdentifiers

extension PlayerModel {
    static var openableTypes: [UTType] {
        (AudioFormats.playable.union(AudioFormats.playlists)).compactMap { UTType(filenameExtension: $0) }
            + [.audio, .folder]
    }

    func showOpenPanel(replace: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = Self.openableTypes
        panel.message = "Choose audio files or folders"
        guard panel.runModal() == .OK else { return }
        if replace { clear() }
        add(urls: panel.urls, playFirst: replace || !isPlaying)
    }

    func showSavePanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "m3u8") ?? .plainText]
        panel.nameFieldStringValue = "Playlist.m3u8"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Playlist.write(tracks, to: url) } catch { message = error.localizedDescription }
    }
}
