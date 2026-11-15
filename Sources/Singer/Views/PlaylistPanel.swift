import SwiftUI

struct PlaylistPanel: View {
    @Environment(PlayerModel.self) private var model
    @State private var tab: Tab = .playlist

    enum Tab { case playlist, chapters }

    var body: some View {
        let hasChapters = model.currentTrack?.chapters.isEmpty == false
        VStack(spacing: 6) {
            HStack {
                tabButton("PLAYLIST", .playlist)
                if hasChapters { tabButton("CHAPTERS", .chapters) }
                Spacer()
            }

            Group {
                if tab == .chapters, hasChapters {
                    ChapterList()
                } else {
                    TrackList()
                }
            }
            .lcd()

            HStack(spacing: 3) {
                Menu {
                    Button("Add Files or Folders…") { model.showOpenPanel() }
                    Button("Open Playlist (Replace)…") { model.showOpenPanel(replace: true) }
                } label: { menuLabel("+ ADD") }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()

                Menu {
                    Button("Remove Selected") { model.remove(model.selection) }
                        .disabled(model.selection.isEmpty)
                    Button("Crop to Selection") { model.crop(to: model.selection) }
                        .disabled(model.selection.isEmpty)
                    Divider()
                    Button("Clear Playlist") { model.clear() }
                } label: { menuLabel("− REM") }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()

                Menu {
                    Button("Sort by Title") { model.sort(by: .title) }
                    Button("Sort by Artist / Album") { model.sort(by: .artist) }
                    Button("Sort by Album") { model.sort(by: .album) }
                    Button("Sort by File Path") { model.sort(by: .path) }
                    Button("Sort by Length") { model.sort(by: .duration) }
                    Button("Randomize") { model.sort(by: .random) }
                    Divider()
                    Button("Save Playlist…") { model.showSavePanel() }
                } label: { menuLabel("MISC") }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()

                Spacer()
                Text(summary)
                    .font(Theme.lcdFont(10))
                    .foregroundStyle(Theme.lcdText)
                    .padding(.horizontal, 4)
                    .frame(height: 18)
                    .lcd()
            }
        }
        .padding(8)
        .panel()
        .onChange(of: hasChapters) { _, has in if !has { tab = .playlist } }
    }

    private var summary: String {
        let sel = model.selection.isEmpty ? "" : "\(model.selection.count)/"
        return "\(sel)\(model.tracks.count) tracks · \(formatTime(model.totalDuration))"
    }

    private func tabButton(_ title: String, _ value: Tab) -> some View {
        Button { tab = value } label: {
            Text(title)
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(tab == value ? Theme.lcdText : Theme.label.opacity(0.7))
        }
        .buttonStyle(.plain)
    }

    private func menuLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .foregroundStyle(Theme.label)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(LinearGradient(colors: [Color(white: 0.42), Color(white: 0.22)], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.7)))
            .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}

struct TrackList: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollViewReader { proxy in
            List(selection: $model.selection) {
                ForEach(Array(model.tracks.enumerated()), id: \.element.id) { index, track in
                    TrackRow(index: index, track: track, isCurrent: track.id == model.currentID)
                        .listRowBackground(model.selection.contains(track.id) ? Theme.selection : Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                        .tag(track.id)
                }
                .onMove { model.move(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 16)
            .contextMenu(forSelectionType: Track.ID.self) { ids in
                if let id = ids.first {
                    Button("Play") { model.play(id) }
                }
                Button("Remove") { model.remove(ids) }
                Button("Show in Finder") {
                    let urls = model.tracks.filter { ids.contains($0.id) }.map(\.url)
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
            } primaryAction: { ids in
                if let id = ids.first { model.play(id) }
            }
            .onDeleteCommand { model.remove(model.selection) }
            .onChange(of: model.currentID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id) } }
            }
            .overlay {
                if model.tracks.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "music.note.list").font(.system(size: 26))
                        Text("Drop files or folders here\nor press ⌘O")
                            .multilineTextAlignment(.center)
                        Text("MP3 · M4A · M4B · FLAC · ALAC · WAV · AIFF"
                             + (AudioFormats.ffmpegPath != nil ? "\nAPE · WV · TTA · DSD · OGG · OPUS" : ""))
                            .font(Theme.lcdFont(9))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.lcdDim)
                    }
                    .font(Theme.lcdFont(11))
                    .foregroundStyle(Theme.lcdText)
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

struct TrackRow: View {
    let index: Int
    let track: Track
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text("\(index + 1).")
                .frame(minWidth: 26, alignment: .trailing)
            Text(track.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if track.isLossless {
                Text(track.codec.isEmpty ? "LL" : track.codec)
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(Theme.accent.opacity(0.8))
            }
            Text(track.duration > 0 ? formatTime(track.duration) : "")
                .monospacedDigit()
        }
        .font(Theme.lcdFont(11, weight: isCurrent ? .bold : .regular))
        .foregroundStyle(isCurrent ? Theme.current : Theme.lcdText)
        .contentShape(Rectangle())
    }
}

struct ChapterList: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        let chapters = model.currentTrack?.chapters ?? []
        let current = model.currentChapterIndex
        ScrollViewReader { proxy in
            List {
                ForEach(chapters) { c in
                    HStack(spacing: 4) {
                        Text("\(c.index + 1).").frame(minWidth: 26, alignment: .trailing)
                        Text(c.title).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(formatTime(c.start)).monospacedDigit().foregroundStyle(Theme.lcdDim)
                        Text(formatTime(c.duration)).monospacedDigit()
                    }
                    .font(Theme.lcdFont(11, weight: c.index == current ? .bold : .regular))
                    .foregroundStyle(c.index == current ? Theme.current : Theme.lcdText)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.seek(to: c.start); if !model.isPlaying { model.togglePause() } }
                    .listRowBackground(Color.clear)
                    .id(c.index)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 16)
            .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
            .onChange(of: current) { _, i in if let i { withAnimation { proxy.scrollTo(i) } } }
        }
    }
}
