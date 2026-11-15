import Foundation
import Observation

/// Kept separate from PlayerModel so 40 fps visualizer updates only redraw the visualizer.
@MainActor @Observable
final class VisualizerState {
    enum Mode: Int { case spectrum, oscilloscope, off }

    var bars = [Float](repeating: 0, count: 20)
    var peaks = [Float](repeating: 0, count: 20)
    var wave = [Float](repeating: 0, count: 64)
    var mode: Mode = Mode(rawValue: UserDefaults.standard.integer(forKey: "visMode")) ?? .spectrum {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "visMode") }
    }

    func update(bars new: [Float], wave: [Float]) {
        guard mode != .off else { return }
        for i in bars.indices where i < new.count {
            bars[i] = max(new[i], bars[i] - 0.06)
            peaks[i] = new[i] >= peaks[i] ? new[i] : max(0, peaks[i] - 0.012)
        }
        self.wave = wave
    }

    func decay() {
        for i in bars.indices {
            bars[i] = max(0, bars[i] - 0.08)
            peaks[i] = max(0, peaks[i] - 0.02)
        }
        wave = wave.map { $0 * 0.5 }
    }

    func cycleMode() {
        mode = Mode(rawValue: (mode.rawValue + 1) % 3) ?? .spectrum
        if mode == .off { decay() }
    }
}
