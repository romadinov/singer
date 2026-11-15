import SwiftUI

struct SyncWindow: View {
    @State private var server = SyncServer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Let Singer on iPhone sync over Wi-Fi", isOn: $server.enabled)
                .toggleStyle(.switch)

            HStack(alignment: .firstTextBaseline) {
                Text("PIN").font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.label)
                Text(server.pin)
                    .font(Theme.lcdFont(30, weight: .bold))
                    .foregroundStyle(server.enabled ? Theme.lcdText : Theme.lcdDim)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .lcd()
                Button("New PIN") { server.regeneratePIN() }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(server.status)
                if let a = server.activity { Text(a).foregroundStyle(.secondary) }
            }
            .font(Theme.lcdFont(11))
            .foregroundStyle(Theme.lcdText)

            Text("On the iPhone, open Singer → SYNC, pick “\(server.name)” and enter the PIN. "
                 + "The iPhone sees this Mac's playlist; formats iOS can't play (APE, DSD, Ogg…) are converted to FLAC/PCM on the way. "
                 + "Audiobook positions sync both ways.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 420)
        .background(Theme.panelGradient)
        .preferredColorScheme(.dark)
    }
}
