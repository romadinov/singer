import SwiftUI

struct EqualizerPanel: View {
    @Environment(PlayerModel.self) private var model
    private let labels = ["60", "170", "310", "600", "1K", "3K", "6K", "12K", "14K", "16K"]

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                RetroButton(text: "ON", active: model.eqEnabled, help: "Enable equalizer") { model.eqEnabled.toggle() }
                Text("EQUALIZER")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(Theme.label)
                    .frame(maxWidth: .infinity)
                Menu {
                    ForEach(PlayerModel.eqPresets) { p in
                        Button(p.name) { model.applyPreset(p) }
                    }
                } label: {
                    Text("PRESETS")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.label)
                        .padding(.horizontal, 6)
                        .frame(height: 22)
                        .background(LinearGradient(colors: [Color(white: 0.42), Color(white: 0.22)],
                                                   startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.7)))
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            HStack(alignment: .bottom, spacing: 0) {
                band(value: $model.preamp, label: "PRE")
                    .frame(width: 34)
                VStack(alignment: .trailing, spacing: 0) {
                    Text("+12").frame(maxHeight: .infinity, alignment: .top)
                    Text("0").frame(maxHeight: .infinity)
                    Text("-12").frame(maxHeight: .infinity, alignment: .bottom)
                }
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Theme.label)
                .frame(width: 18, height: 76)
                .padding(.bottom, 14)
                .padding(.trailing, 4)

                VStack(spacing: 4) {
                    EQCurve(gains: model.eqGains, enabled: model.eqEnabled)
                        .frame(height: 20)
                        .lcd()
                    HStack(spacing: 0) {
                        ForEach(0..<10, id: \.self) { i in
                            band(value: $model.eqGains[i], label: labels[i])
                        }
                    }
                }
            }
            .opacity(model.eqEnabled ? 1 : 0.5)
        }
        .padding(8)
        .panel()
    }

    private func band(value: Binding<Double>, label: String) -> some View {
        VStack(spacing: 3) {
            VerticalSlider(value: value)
                .frame(height: 76)
                .help(String(format: "%@: %+.1f dB (double-click to reset)", label, value.wrappedValue))
            Text(label).font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.label)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Smooth curve preview of the EQ bands, like the classic skin's graph.
struct EQCurve: View {
    let gains: [Double]
    let enabled: Bool

    var body: some View {
        Canvas { ctx, size in
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: 0, y: size.height / 2))
                p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            }, with: .color(Theme.lcdDim.opacity(0.6)), lineWidth: 0.5)

            let pts = gains.enumerated().map { i, g in
                CGPoint(x: size.width * (CGFloat(i) + 0.5) / CGFloat(gains.count),
                        y: size.height / 2 - CGFloat(g / 12) * (size.height / 2 - 2))
            }
            guard pts.count > 1 else { return }
            var path = Path()
            path.move(to: CGPoint(x: 0, y: pts[0].y))
            path.addLine(to: pts[0])
            for i in 1..<pts.count {
                let a = pts[i - 1], b = pts[i]
                let mid = (a.x + b.x) / 2
                path.addCurve(to: b, control1: CGPoint(x: mid, y: a.y), control2: CGPoint(x: mid, y: b.y))
            }
            path.addLine(to: CGPoint(x: size.width, y: pts.last!.y))
            ctx.stroke(path, with: .color(enabled ? Theme.lcdText : Theme.lcdDim), lineWidth: 1.2)
        }
    }
}
