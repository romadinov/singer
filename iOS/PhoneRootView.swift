import SwiftUI
import UniformTypeIdentifiers

struct PhoneRootView: View {
    @Environment(PlayerModel.self) private var model
    @AppStorage("phoneTab") private var tab: Tab = .playlist

    enum Tab: String, CaseIterable {
        case playlist = "PLAYLIST", chapters = "CHAPTERS", eq = "EQ", sync = "SYNC"
    }

    var body: some View {
        let hasChapters = model.currentTrack?.chapters.isEmpty == false
        VStack(spacing: 0) {
            PhonePlayerPanel()
            HStack(spacing: 4) {
                ForEach(Tab.allCases.filter { $0 != .chapters || hasChapters }, id: \.self) { t in
                    Button { tab = t } label: {
                        Text(t.rawValue)
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .tracking(1.2)
                            .foregroundStyle(tab == t ? Theme.lcdText : Theme.label.opacity(0.7))
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(tab == t ? Color.black.opacity(0.45) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .panel()

            Group {
                switch tab == .chapters && !hasChapters ? .playlist : tab {
                case .playlist: PhonePlaylist()
                case .chapters: PhoneChapters()
                case .eq: ScrollView { EqualizerPanel() }
                case .sync: SyncView()
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(Theme.panelGradient.ignoresSafeArea())
    }
}

struct PhonePlayerPanel: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            TitleStripPhone()

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: model.isPlaying ? "play.fill" : model.isPaused ? "pause.fill" : "stop.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(model.isPlaying ? Theme.lcdText : Theme.lcdDim)
                        TimeDisplay()
                    }
                    VisualizerView().frame(height: 34)
                }
                .padding(6)
                .frame(width: 150, height: 86, alignment: .topLeading)
                .lcd()

                VStack(alignment: .leading, spacing: 6) {
                    Marquee(text: marqueeText)
                        .frame(height: 20)
                        .padding(.horizontal, 4)
                        .lcd()
                    HStack(spacing: 6) {
                        SpeedMenu()
                        Spacer(minLength: 0)
                        RetroButton(symbol: "shuffle", active: model.shuffle, width: 40, height: 30) {
                            model.shuffle.toggle()
                        }
                        RetroButton(symbol: model.repeatMode == .one ? "repeat.1" : "repeat",
                                    active: model.repeatMode != .off, width: 40, height: 30) {
                            model.cycleRepeat()
                        }
                    }
                    StreamInfo()
                }
            }

            HStack {
                Text(formatTime(model.position))
                Spacer()
                Text("-" + formatTime(max(0, model.duration - model.position)))
            }
            .font(Theme.lcdFont(10))
            .foregroundStyle(Theme.lcdDim)
            .padding(.bottom, -6)
            SeekBar().padding(.vertical, 6)

            HStack(spacing: 6) {
                if model.currentTrack?.chapters.isEmpty == false {
                    transport("chevron.backward.2") { model.previousChapter() }
                } else {
                    transport("gobackward.15") { model.skip(-15) }
                }
                transport("backward.end.fill") { model.previous() }
                transport(model.isPlaying ? "pause.fill" : "play.fill", big: true) {
                    model.isPlaying || model.isPaused ? model.togglePause() : model.playPressed()
                }
                transport("stop.fill") { model.stop() }
                transport("forward.end.fill") { model.next() }
                if model.currentTrack?.chapters.isEmpty == false {
                    transport("chevron.forward.2") { model.nextChapter() }
                } else {
                    transport("goforward.30") { model.skip(30) }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .panel()
    }

    private func transport(_ symbol: String, big: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: big ? 20 : 15, weight: .bold))
                .foregroundStyle(big ? Theme.lcdText : Theme.label)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(LinearGradient(colors: [Color(white: 0.42), Color(white: 0.22)],
                                           startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black.opacity(0.7)))
                .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.25)).frame(height: 1).padding(1) }
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: model.isPlaying)
    }

    private var marqueeText: String {
        if let msg = model.message { return msg }
        guard let t = model.currentTrack else { return "Singer — sync from your Mac or import files" }
        var s = "\(model.currentIndex.map { "\($0 + 1). " } ?? "")\(t.displayTitle)"
        if let i = model.currentChapterIndex { s += "  ·  \(t.chapters[i].title)" }
        return s + " (\(formatTime(t.duration > 0 ? t.duration : model.duration)))"
    }
}

private struct TitleStripPhone: View {
    var body: some View {
        HStack(spacing: 8) {
            stripes
            Text("SINGER")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .tracking(3)
                .foregroundStyle(Theme.label)
            stripes
        }
        .frame(height: 20)
    }

    private var stripes: some View {
        VStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { _ in Rectangle().fill(Theme.accent.opacity(0.45)).frame(height: 1) }
        }
    }
}

struct PhonePlaylist: View {
    @Environment(PlayerModel.self) private var model
    @State private var importing = false
    @State private var editMode: EditMode = .inactive

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(model.tracks.enumerated()), id: \.element.id) { index, track in
                        PhoneTrackRow(index: index, track: track, isCurrent: track.id == model.currentID)
                            .contentShape(Rectangle())
                            .onTapGesture { model.play(track.id) }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                            .id(track.id)
                    }
                    .onDelete { offsets in model.remove(Set(offsets.map { model.tracks[$0].id })) }
                    .onMove { model.move(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 34)
                .environment(\.editMode, $editMode)
                .onChange(of: model.currentID) { _, id in if let id { withAnimation { proxy.scrollTo(id) } } }
                .overlay {
                    if model.tracks.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "music.note.list").font(.system(size: 30))
                            Text("No music yet.\nUse SYNC to copy from your Mac,\n+ to import from Files,\nor drop files on Singer in Finder.")
                                .multilineTextAlignment(.center)
                        }
                        .font(Theme.lcdFont(12))
                        .foregroundStyle(Theme.lcdText)
                    }
                }
            }
            .lcd()
            .padding(.horizontal, 8)
            .padding(.top, 6)

            HStack(spacing: 6) {
                RetroButton(text: "+ IMPORT", height: 30) { importing = true }
                RetroButton(text: editMode.isEditing ? "DONE" : "EDIT", active: editMode.isEditing, height: 30) {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
                Menu {
                    Button("Sort by Title") { model.sort(by: .title) }
                    Button("Sort by Artist / Album") { model.sort(by: .artist) }
                    Button("Sort by Length") { model.sort(by: .duration) }
                    Button("Randomize") { model.sort(by: .random) }
                } label: {
                    RetroButton(text: "SORT", height: 30) {}.allowsHitTesting(false)
                }
                Spacer()
                Text("\(model.tracks.count) · \(formatTime(model.totalDuration))")
                    .font(Theme.lcdFont(10))
                    .foregroundStyle(Theme.lcdText)
                    .padding(.horizontal, 5)
                    .frame(height: 22)
                    .lcd()
            }
            .padding(8)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.importTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { PhoneLibrary.importFiles(urls) }
        }
    }

    static let importTypes: [UTType] =
        AudioFormats.native.compactMap { UTType(filenameExtension: $0) } + [.audio]
}

struct PhoneTrackRow: View {
    let index: Int
    let track: Track
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text("\(index + 1).")
                .frame(minWidth: 28, alignment: .trailing)
                .foregroundStyle(isCurrent ? Theme.current : Theme.lcdDim)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).lineLimit(1)
                if let a = track.artist ?? track.album {
                    Text(a).font(Theme.lcdFont(9)).foregroundStyle(Theme.lcdDim).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if track.isLossless {
                Text(track.codec.isEmpty ? "LL" : track.codec)
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(Theme.accent.opacity(0.85))
            }
            if !track.chapters.isEmpty {
                Image(systemName: "book.closed.fill").font(.system(size: 9)).foregroundStyle(Theme.accent.opacity(0.85))
            }
            Text(track.duration > 0 ? formatTime(track.duration) : "").monospacedDigit()
        }
        .font(Theme.lcdFont(12, weight: isCurrent ? .bold : .regular))
        .foregroundStyle(isCurrent ? Theme.current : Theme.lcdText)
    }
}

struct PhoneChapters: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        let chapters = model.currentTrack?.chapters ?? []
        let current = model.currentChapterIndex
        ScrollViewReader { proxy in
            List(chapters) { c in
                HStack(spacing: 6) {
                    Text("\(c.index + 1).").frame(minWidth: 28, alignment: .trailing)
                    Text(c.title).lineLimit(2)
                    Spacer(minLength: 4)
                    Text(formatTime(c.duration)).monospacedDigit().foregroundStyle(Theme.lcdDim)
                }
                .font(Theme.lcdFont(12, weight: c.index == current ? .bold : .regular))
                .foregroundStyle(c.index == current ? Theme.current : Theme.lcdText)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.seek(to: c.start)
                    if !model.isPlaying { model.togglePause() }
                }
                .listRowBackground(Color.clear)
                .id(c.index)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
            .onChange(of: current) { _, i in if let i { withAnimation { proxy.scrollTo(i) } } }
        }
        .lcd()
        .padding(8)
    }
}
