import SwiftUI

enum Theme {
    static let panelTop = Color(red: 0.24, green: 0.24, blue: 0.32)
    static let panelBottom = Color(red: 0.13, green: 0.13, blue: 0.18)
    static let bevelLight = Color.white.opacity(0.18)
    static let bevelDark = Color.black.opacity(0.6)
    static let lcd = Color.black
    static let lcdText = Color(red: 0.0, green: 0.95, blue: 0.2)
    static let lcdDim = Color(red: 0.0, green: 0.45, blue: 0.1)
    static let accent = Color(red: 0.95, green: 0.75, blue: 0.2)
    static let current = Color.white
    static let selection = Color(red: 0.0, green: 0.2, blue: 0.75)
    static let label = Color(red: 0.75, green: 0.78, blue: 0.9)

    static func lcdFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static let panelGradient = LinearGradient(colors: [panelTop, panelBottom], startPoint: .top, endPoint: .bottom)
}

/// Beveled panel background, like the classic skin.
struct PanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.panelGradient)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(LinearGradient(colors: [Theme.bevelLight, Theme.bevelDark],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            )
    }
}

/// Sunken black LCD area.
struct LCDBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.lcd)
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .strokeBorder(LinearGradient(colors: [Theme.bevelDark, Theme.bevelLight],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            )
    }
}

extension View {
    func panel() -> some View { modifier(PanelBackground()) }
    func lcd() -> some View { modifier(LCDBackground()) }
}

/// Small raised button with an SF Symbol or text.
struct RetroButton: View {
    var symbol: String?
    var text: String?
    var active = false
    var width: CGFloat? = nil
    var height: CGFloat = 22
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                } else if let text {
                    Text(text).font(.system(size: 9, weight: .heavy, design: .rounded))
                }
            }
            .foregroundStyle(active ? Theme.lcdText : Theme.label)
            .frame(width: width, height: height)
            .frame(minWidth: 26)
            .padding(.horizontal, text != nil && width == nil ? 6 : 0)
            .background(
                LinearGradient(colors: [Color(white: 0.42), Color(white: 0.22)], startPoint: .top, endPoint: .bottom)
            )
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.7), lineWidth: 1))
            .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.25)).frame(height: 1).padding(1) }
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .shadow(color: active ? Theme.lcdText.opacity(0.5) : .clear, radius: 3)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Horizontal groove slider with a raised thumb. Calls `onCommit` when the drag ends.
struct RetroSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var fill: Color = Theme.lcdText
    var centered = false
    var thumbWidth: CGFloat = 14
    var onDrag: ((Bool) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - thumbWidth
            let frac = range.upperBound > range.lowerBound
                ? (value - range.lowerBound) / (range.upperBound - range.lowerBound) : 0
            let x = CGFloat(min(max(frac, 0), 1)) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black).frame(height: 5)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
                    .padding(.horizontal, thumbWidth / 2)
                if centered {
                    let mid = w / 2
                    Rectangle().fill(fill.opacity(0.8))
                        .frame(width: abs(x - mid), height: 3)
                        .offset(x: thumbWidth / 2 + min(x, mid))
                } else {
                    Capsule().fill(fill.opacity(0.85)).frame(width: max(0, x), height: 3)
                        .offset(x: thumbWidth / 2)
                }
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.45)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.6), lineWidth: 0.5))
                    .frame(width: thumbWidth, height: 10)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        onDrag?(true)
                        let f = min(max((g.location.x - thumbWidth / 2) / max(w, 1), 0), 1)
                        var v = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                        if centered, abs(f - 0.5) < 0.04 { v = (range.lowerBound + range.upperBound) / 2 }
                        value = v
                    }
                    .onEnded { _ in onDrag?(false) }
            )
        }
        .frame(height: 14)
    }
}

/// Vertical slider for the equalizer. Double-click resets to 0.
struct VerticalSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = -12...12

    var body: some View {
        GeometryReader { geo in
            let thumb: CGFloat = 8
            let h = geo.size.height - thumb
            let frac = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let y = (1 - CGFloat(frac)) * h
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 2).fill(Color.black).frame(width: 5)
                    .padding(.vertical, thumb / 2)
                Rectangle()
                    .fill(LinearGradient(colors: [.red, .yellow, Theme.lcdText, .yellow, .red],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 3, height: abs(y - h / 2))
                    .offset(y: thumb / 2 + min(y, h / 2))
                    .opacity(0.85)
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.45)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.6), lineWidth: 0.5))
                    .frame(width: 14, height: thumb)
                    .offset(y: y)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    let f = 1 - min(max((g.location.y - thumb / 2) / max(h, 1), 0), 1)
                    var v = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                    if abs(v) < 0.6 { v = 0 }
                    value = (v * 2).rounded() / 2
                }
            )
            .onTapGesture(count: 2) { value = 0 }
        }
    }
}
