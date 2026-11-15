import SwiftUI

struct SyncView: View {
    @Environment(SyncClient.self) private var sync
    @State private var pinEntry = ""
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 8) {
            switch sync.state {
            case .idle:
                peerList
            case .connecting:
                Spacer()
                ProgressView("Connecting to \(sync.peer?.name ?? "Mac")…").tint(Theme.lcdText)
                Spacer()
            case .needsPIN:
                pinForm
            case .failed(let msg):
                VStack(spacing: 10) {
                    Text(msg).multilineTextAlignment(.center)
                    HStack {
                        RetroButton(text: "RETRY", height: 32) { if let p = sync.peer { sync.connect(p) } }
                        RetroButton(text: "BACK", height: 32) { sync.disconnect() }
                    }
                }
                .font(Theme.lcdFont(12))
                .foregroundStyle(Theme.lcdText)
                .frame(maxHeight: .infinity)
            case .connected:
                library
            }
            if let e = sync.error {
                Text(e).font(Theme.lcdFont(10)).foregroundStyle(.orange).lineLimit(3)
                    .onTapGesture { sync.error = nil }
            }
        }
        .padding(8)
        .onAppear { sync.startBrowsing() }
    }

    private var peerList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MACS ON THIS NETWORK")
                .font(.system(size: 10, weight: .heavy, design: .rounded)).tracking(1.5)
                .foregroundStyle(Theme.label)
            List(sync.peers) { p in
                Button { sync.connect(p) } label: {
                    HStack {
                        Image(systemName: "laptopcomputer")
                        Text(p.name)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Theme.lcdDim)
                    }
                    .font(Theme.lcdFont(13))
                    .foregroundStyle(Theme.lcdText)
                    .frame(minHeight: 40)
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if sync.peers.isEmpty {
                    VStack(spacing: 8) {
                        ProgressView().tint(Theme.lcdText)
                        Text("Looking for Singer on your Mac…\n\nOn the Mac: File → iPhone Sync…\nand turn sharing on. Both devices\nneed to be on the same Wi-Fi.")
                            .multilineTextAlignment(.center)
                    }
                    .font(Theme.lcdFont(11))
                    .foregroundStyle(Theme.lcdText)
                }
            }
            .lcd()
        }
    }

    private var pinForm: some View {
        VStack(spacing: 12) {
            Text("Enter the PIN shown on\n\(sync.peer?.name ?? "the Mac") → iPhone Sync")
                .multilineTextAlignment(.center)
                .font(Theme.lcdFont(12))
                .foregroundStyle(Theme.lcdText)
            TextField("000000", text: $pinEntry)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(Theme.lcdFont(30, weight: .bold))
                .foregroundStyle(Theme.lcdText)
                .frame(width: 200, height: 54)
                .lcd()
            HStack {
                RetroButton(text: "CONNECT", active: pinEntry.count == 6, height: 34) {
                    if let p = sync.peer { sync.connect(p, pin: pinEntry) }
                }
                RetroButton(text: "CANCEL", height: 34) { sync.disconnect() }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var library: some View {
        let tracks = (sync.remote?.tracks ?? []).filter {
            filter.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(filter)
                || ($0.album ?? "").localizedCaseInsensitiveContains(filter)
        }
        return VStack(spacing: 6) {
            HStack {
                Image(systemName: "laptopcomputer").foregroundStyle(Theme.lcdText)
                Text(sync.remote?.name ?? "").lineLimit(1)
                Spacer()
                Button { Task { try? await sync.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                Button { sync.disconnect() } label: { Image(systemName: "xmark.circle") }
            }
            .font(Theme.lcdFont(12))
            .foregroundStyle(Theme.label)

            TextField("Filter", text: $filter)
                .font(Theme.lcdFont(12))
                .foregroundStyle(Theme.lcdText)
                .padding(6)
                .lcd()

            List(tracks, id: \.syncID) { t in
                RemoteRow(track: t)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 34)
            .lcd()

            HStack(spacing: 6) {
                if sync.queued.isEmpty && sync.downloading.isEmpty {
                    RetroButton(text: "GET ALL (\(sync.missingCount))", active: sync.missingCount > 0, height: 32) {
                        sync.downloadAll()
                    }
                } else {
                    RetroButton(text: "STOP", active: true, height: 32) { sync.cancelDownloads() }
                    Text("\(sync.queued.count + sync.downloading.count) left")
                        .font(Theme.lcdFont(11)).foregroundStyle(Theme.lcdText)
                }
                Spacer()
                RetroButton(text: "SYNC POSITIONS", height: 32) { Task { try? await sync.syncPositions() } }
            }
            if let d = sync.lastSync {
                Text("Positions synced \(d.formatted(date: .omitted, time: .shortened))")
                    .font(Theme.lcdFont(9)).foregroundStyle(Theme.lcdDim)
            }
        }
    }
}

private struct RemoteRow: View {
    @Environment(SyncClient.self) private var sync
    let track: Track

    var body: some View {
        let id = track.syncID ?? ""
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).lineLimit(1)
                Text([track.artist, track.album].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.lcdFont(9)).foregroundStyle(Theme.lcdDim).lineLimit(1)
            }
            Spacer(minLength: 4)
            if track.isLossless {
                Text(track.codec).font(.system(size: 8, weight: .heavy)).foregroundStyle(Theme.accent.opacity(0.85))
            }
            Text(formatTime(track.duration)).monospacedDigit().foregroundStyle(Theme.lcdDim)
            Group {
                if sync.isLocal(id) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.lcdText)
                } else if let p = sync.progress[id] {
                    ProgressView(value: p).progressViewStyle(.circular).tint(Theme.accent).scaleEffect(0.7)
                } else if sync.queued.contains(id) {
                    Image(systemName: "clock").foregroundStyle(Theme.lcdDim)
                } else {
                    Button { sync.download([id]) } label: {
                        Image(systemName: "arrow.down.circle").foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 28, height: 28)
        }
        .font(Theme.lcdFont(12))
        .foregroundStyle(Theme.lcdText)
    }
}
