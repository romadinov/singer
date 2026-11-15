import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--probe") {
            Probe.run(Array(args[(i + 1)...]))
            return
        }
        if let i = args.firstIndex(of: "--snapshot") {
            MainActor.assumeIsolated { Snapshot.run(Array(args[(i + 1)...])) }
            return
        }
        SingerApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            let model = PlayerModel.shared
            model.add(urls: urls, playFirst: true)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Files passed on the command line: `Singer song.flac folder/`
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if !paths.isEmpty {
            MainActor.assumeIsolated {
                PlayerModel.shared.add(urls: paths.map { URL(fileURLWithPath: $0) }, playFirst: true)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { PlayerModel.shared.applicationWillTerminate() }
    }
}

struct SingerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = PlayerModel.shared

    var body: some Scene {
        Window("Singer", id: "main") {
            ContentView()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 480, height: 640)
        .commands { PlayerCommands(model: model) }
    }
}

struct ContentView: View {
    @Environment(PlayerModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            MainPanel()
            if model.showEqualizer { EqualizerPanel() }
            if model.showPlaylist {
                PlaylistPanel().frame(minHeight: 160, maxHeight: .infinity)
            }
        }
        .frame(width: 480)
        .frame(maxHeight: model.showPlaylist ? .infinity : nil)
        .fixedSize(horizontal: false, vertical: !model.showPlaylist)
        .background(Theme.panelBottom)
        .preferredColorScheme(.dark)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.lcdText, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for p in providers {
                    if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let u = URL(dataRepresentation: url, relativeTo: nil) {
                        urls.append(u)
                    }
                }
                model.add(urls: urls, playFirst: !model.isPlaying && !model.isPaused)
            }
            return true
        }
        .ignoresSafeArea()
    }
}

struct PlayerCommands: Commands {
    let model: PlayerModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Files or Folders…") { model.showOpenPanel() }
                .keyboardShortcut("o")
            Button("Open (Replace Playlist)…") { model.showOpenPanel(replace: true) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Save Playlist…") { model.showSavePanel() }
                .keyboardShortcut("s")
        }
        CommandMenu("Playback") {
            Button("Previous") { model.previous() }.keyboardShortcut("z", modifiers: [])
            Button("Play") { model.playPressed() }.keyboardShortcut("x", modifiers: [])
            Button("Pause / Resume") { model.togglePause() }.keyboardShortcut("c", modifiers: [])
            Button("Play / Pause") { model.togglePause() }.keyboardShortcut(.space, modifiers: [])
            Button("Stop") { model.stop() }.keyboardShortcut("v", modifiers: [])
            Button("Next") { model.next() }.keyboardShortcut("b", modifiers: [])
            Divider()
            Button("Previous Chapter") { model.previousChapter() }.keyboardShortcut("[", modifiers: [])
            Button("Next Chapter") { model.nextChapter() }.keyboardShortcut("]", modifiers: [])
            Button("Back 10 Seconds") { model.skip(-10) }.keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Forward 10 Seconds") { model.skip(10) }.keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Back 1 Minute") { model.skip(-60) }.keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            Button("Forward 1 Minute") { model.skip(60) }.keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
            Divider()
            Button("Volume Up") { model.volume = min(1, model.volume + 0.05) }.keyboardShortcut(.upArrow, modifiers: .command)
            Button("Volume Down") { model.volume = max(0, model.volume - 0.05) }.keyboardShortcut(.downArrow, modifiers: .command)
            Menu("Speed") {
                ForEach(PlayerModel.speeds, id: \.self) { s in
                    Button(String(format: "%g×", s)) { model.rate = s }
                }
            }
            Divider()
            Button("Shuffle") { model.shuffle.toggle() }.keyboardShortcut("s", modifiers: [])
            Button("Cycle Repeat (Off / All / One)") { model.cycleRepeat() }.keyboardShortcut("r", modifiers: [])
        }
        CommandGroup(before: .toolbar) {
            Button("Equalizer") { model.showEqualizer.toggle() }.keyboardShortcut("g", modifiers: .option)
            Button("Playlist") { model.showPlaylist.toggle() }.keyboardShortcut("e", modifiers: .option)
            Button("Toggle Elapsed / Remaining") { model.showRemaining.toggle() }.keyboardShortcut("t", modifiers: .command)
            Button("Cycle Visualizer") { model.visualizer.cycleMode() }.keyboardShortcut("k", modifiers: .command)
            Divider()
        }
    }
}
