import SwiftUI

struct MainPanel: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 6) {
            TitleStrip(title: "SINGER")

            HStack(alignment: .top, spacing: 6) {
                // Left LCD: state, time, visualizer
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: model.isPlaying ? "play.fill" : model.isPaused ? "pause.fill" : "stop.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(model.isPlaying ? Theme.lcdText : Theme.lcdDim)
                        TimeDisplay()
                    }
                    VisualizerView()
                        .frame(height: 34)
                }
                .padding(6)
                .frame(width: 150, height: 86, alignment: .topLeading)
                .lcd()

                // Right: marquee, stream info, sliders
                VStack(alignment: .leading, spacing: 5) {
                    Marquee(text: marqueeText)
                        .frame(height: 18)
                        .padding(.horizontal, 4)
                        .lcd()
                    StreamInfo()
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.wave.2.fill").font(.system(size: 9)).foregroundStyle(Theme.label)
                        RetroSlider(value: $model.volume, fill: volumeColor)
                            .help("Volume \(Int(model.volume * 100))%")
                        Text("BAL").font(.system(size: 8, weight: .heavy)).foregroundStyle(Theme.label)
                        RetroSlider(value: $model.balance, range: -1...1, fill: Theme.accent, centered: true)
                            .frame(width: 60)
                            .help(balanceHelp)
                    }
                    HStack(spacing: 4) {
                        Spacer()
                        RetroButton(text: "EQ", active: model.showEqualizer, help: "Equalizer (⌥G)") {
                            model.showEqualizer.toggle()
                        }
                        RetroButton(text: "PL", active: model.showPlaylist, help: "Playlist (⌥E)") {
                            model.showPlaylist.toggle()
                        }
                    }
                }
            }

            SeekBar()

            HStack(spacing: 3) {
                RetroButton(symbol: "backward.end.fill", width: 34, help: "Previous (Z)") { model.previous() }
                RetroButton(symbol: "play.fill", width: 34, help: "Play (X)") { model.playPressed() }
                RetroButton(symbol: "pause.fill", width: 34, help: "Pause (C)") { model.togglePause() }
                RetroButton(symbol: "stop.fill", width: 34, help: "Stop (V)") { model.stop() }
                RetroButton(symbol: "forward.end.fill", width: 34, help: "Next (B)") { model.next() }
                RetroButton(symbol: "eject.fill", width: 30, help: "Open files (⌘O)") { model.showOpenPanel() }
                if model.currentTrack?.chapters.isEmpty == false {
                    RetroButton(symbol: "chevron.backward.2", width: 26, help: "Previous chapter ([)") { model.previousChapter() }
                    RetroButton(symbol: "chevron.forward.2", width: 26, help: "Next chapter (])") { model.nextChapter() }
                }
                Spacer(minLength: 4)
                SpeedMenu()
                RetroButton(symbol: "shuffle", active: model.shuffle, width: 28, help: "Shuffle (S)") {
                    model.shuffle.toggle()
                }
                RetroButton(symbol: model.repeatMode == .one ? "repeat.1" : "repeat",
                            active: model.repeatMode != .off, width: 28,
                            help: "Repeat: \(["off", "all", "one"][model.repeatMode.rawValue]) (R)") {
                    model.cycleRepeat()
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .panel()
    }

    private var marqueeText: String {
        if let msg = model.message { return msg }
        guard let t = model.currentTrack else { return "Singer — drop some music here" }
        var s = "\(model.currentIndex.map { "\($0 + 1). " } ?? "")\(t.displayTitle)"
        if let i = model.currentChapterIndex { s += "  ·  \(t.chapters[i].title)" }
        return s + " (\(formatTime(t.duration > 0 ? t.duration : model.duration)))"
    }

    private var volumeColor: Color {
        model.volume < 0.6 ? Theme.lcdText : model.volume < 0.85 ? .yellow : .orange
    }

    private var balanceHelp: String {
        let b = Int(model.balance * 100)
        return b == 0 ? "Balance: center" : b < 0 ? "Balance: \(-b)% left" : "Balance: \(b)% right"
    }
}
