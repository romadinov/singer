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

struct TitleStrip: View {
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            stripes
            Text(title)
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .tracking(3)
                .foregroundStyle(Theme.label)
            stripes
        }
        .frame(height: 22)
        .padding(.leading, 64)  // leave room for the traffic lights
    }

    private var stripes: some View {
        VStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { _ in
                Rectangle().fill(Theme.accent.opacity(0.45)).frame(height: 1)
            }
        }
    }
}

struct TimeDisplay: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        let remaining = model.showRemaining && model.duration > 0
        let t = remaining ? max(0, model.duration - model.position) : model.position
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let blink = model.isPaused && Int(ctx.date.timeIntervalSince1970 * 2) % 2 == 0
            HStack(spacing: 0) {
                Text(remaining ? "-" : " ")
                Text(formatTime(t))
            }
            .font(Theme.lcdFont(28, weight: .bold))
            .foregroundStyle(Theme.lcdText)
            .shadow(color: Theme.lcdText.opacity(0.6), radius: 4)
            .opacity(blink ? 0.25 : 1)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .contentShape(Rectangle())
        .onTapGesture { model.showRemaining.toggle() }
        .help("Click to toggle elapsed / remaining")
    }
}

struct StreamInfo: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        let t = model.currentTrack
        HStack(spacing: 4) {
            badge(t.map { $0.bitrateKbps > 0 ? "\($0.bitrateKbps)" : "---" } ?? "---", "kbps")
            badge(t.map { $0.sampleRate > 0 ? sampleRateText($0.sampleRate) : "--" } ?? "--", "kHz")
            if let t, t.bitsPerSample > 0, t.isLossless { badge("\(t.bitsPerSample)", "bit") }
            Spacer(minLength: 2)
            if let t, !t.codec.isEmpty {
                Text(t.codec).font(.system(size: 8, weight: .heavy)).foregroundStyle(Theme.label)
            }
            if t?.isLossless == true {
                Text("LOSSLESS")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 3)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 2))
            }
            Text(t.map { $0.channels == 1 ? "mono" : $0.channels > 2 ? "\($0.channels)ch" : "stereo" } ?? "stereo")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(t == nil ? Theme.lcdDim : Theme.lcdText)
        }
    }

    private func sampleRateText(_ sr: Double) -> String {
        let k = sr / 1000
        return k == k.rounded() ? "\(Int(k))" : String(format: "%.1f", k)
    }

    private func badge(_ value: String, _ unit: String) -> some View {
        HStack(spacing: 2) {
            Text(value)
                .font(Theme.lcdFont(10, weight: .bold))
                .foregroundStyle(Theme.lcdText)
                .padding(.horizontal, 3)
                .lcd()
            Text(unit).font(.system(size: 8, weight: .heavy)).foregroundStyle(Theme.label)
        }
    }
}

/// Classic character-rotating title ticker.
struct Marquee: View {
    let text: String

    var body: some View {
        GeometryReader { geo in
            let charWidth: CGFloat = 6.6
            let visible = Int(geo.size.width / charWidth)
            TimelineView(.periodic(from: .now, by: 0.18)) { ctx in
                Text(rotated(visible: visible, date: ctx.date))
                    .font(Theme.lcdFont(11))
                    .foregroundStyle(Theme.lcdText)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .clipped()
        }
    }

    private func rotated(visible: Int, date: Date) -> String {
        guard text.count > visible else { return text }
        let padded = Array(text + "  ***  ")
        let offset = Int(date.timeIntervalSinceReferenceDate / 0.18) % padded.count
        return String((padded[offset...] + padded[..<offset]).prefix(visible + 1))
    }
}

struct SeekBar: View {
    @Environment(PlayerModel.self) private var model
    @State private var dragValue: Double?

    var body: some View {
        let binding = Binding<Double>(
            get: { dragValue ?? model.position },
            set: { dragValue = $0 }
        )
        ZStack {
            if let t = model.currentTrack, t.duration > 0 {
                // chapter ticks
                GeometryReader { geo in
                    ForEach(t.chapters.dropFirst()) { c in
                        Rectangle().fill(Theme.accent.opacity(0.7))
                            .frame(width: 1, height: 12)
                            .offset(x: 7 + CGFloat(c.start / t.duration) * (geo.size.width - 14))
                    }
                }
                .frame(height: 12)
                .allowsHitTesting(false)
            }
            RetroSlider(value: binding, range: 0...max(model.duration, 0.01), fill: Theme.accent, thumbWidth: 26) { dragging in
                if !dragging, let v = dragValue {
                    model.seek(to: v)
                    dragValue = nil
                }
            }
            .disabled(model.currentTrack == nil)
        }
        .help(dragValue.map { "Seek to \(formatTime($0))" } ?? "Seek")
    }
}

struct SpeedMenu: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        Menu {
            ForEach(PlayerModel.speeds, id: \.self) { s in
                Button {
                    model.rate = s
                } label: {
                    if s == model.rate { Label(speedLabel(s), systemImage: "checkmark") } else { Text(speedLabel(s)) }
                }
            }
        } label: {
            Text(speedLabel(model.rate))
                .font(Theme.lcdFont(10, weight: .bold))
                .foregroundStyle(model.rate == 1 ? Theme.lcdDim : Theme.lcdText)
                .frame(width: 38, height: 18)
                .lcd()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback speed (pitch preserved)")
    }

    private func speedLabel(_ s: Double) -> String {
        s == s.rounded() ? "\(Int(s)).0×" : String(format: "%g×", s)
    }
}

struct VisualizerView: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        let vis = model.visualizer
        Canvas { ctx, size in
            switch vis.mode {
            case .spectrum:
                let n = vis.bars.count
                let gap: CGFloat = 1.5
                let w = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
                let gradient = Gradient(colors: [Theme.lcdText, .yellow, .orange, .red])
                for i in 0..<n {
                    let x = CGFloat(i) * (w + gap)
                    let h = CGFloat(vis.bars[i]) * size.height
                    let rect = CGRect(x: x, y: size.height - h, width: w, height: h)
                    ctx.fill(Path(rect), with: .linearGradient(gradient, startPoint: CGPoint(x: 0, y: size.height),
                                                               endPoint: CGPoint(x: 0, y: 0)))
                    let py = size.height - CGFloat(vis.peaks[i]) * size.height
                    if vis.peaks[i] > 0.02 {
                        ctx.fill(Path(CGRect(x: x, y: max(0, py - 1), width: w, height: 1.5)), with: .color(Color(white: 0.85)))
                    }
                }
            case .oscilloscope:
                var path = Path()
                let pts = vis.wave
                for (i, v) in pts.enumerated() {
                    let x = size.width * CGFloat(i) / CGFloat(max(pts.count - 1, 1))
                    let y = size.height / 2 - CGFloat(max(-1, min(1, v * 1.6))) * size.height / 2
                    i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                }
                ctx.stroke(path, with: .color(Theme.lcdText), lineWidth: 1.2)
            case .off:
                break
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { vis.cycleMode() }
        .help("Click to switch visualizer: spectrum / oscilloscope / off")
    }
}
