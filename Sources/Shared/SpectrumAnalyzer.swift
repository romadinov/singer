import AVFoundation
import Accelerate

/// FFT → log-spaced bars (0…1) plus a downsampled waveform for the oscilloscope.
/// Called only from the audio tap thread.
final class SpectrumAnalyzer {
    let size: Int
    let bands: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var mono: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var mags: [Float]
    private let edges: [Int]

    init(size: Int = 1024, bands: Int = 20) {
        self.size = size
        self.bands = bands
        log2n = vDSP_Length(log2(Double(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        mono = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imag = [Float](repeating: 0, count: size / 2)
        mags = [Float](repeating: 0, count: size / 2)

        // Log-spaced bin edges from ~40 Hz to Nyquist.
        let half = Double(size / 2)
        var e = (0...bands).map { Int(1.0 * pow(half, Double($0) / Double(bands))) }
        for i in 1..<e.count where e[i] <= e[i - 1] { e[i] = e[i - 1] + 1 }
        edges = e.map { min($0, size / 2) }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func process(_ buffer: AVAudioPCMBuffer, offset: Int = 0) -> (bars: [Float], wave: [Float])? {
        guard let data = buffer.floatChannelData else { return nil }
        let n = min(Int(buffer.frameLength) - offset, size)
        let channels = Int(buffer.format.channelCount)
        guard n > 0, channels > 0 else { return nil }

        let scale = 1 / Float(channels)
        for i in 0..<size {
            guard i < n else { mono[i] = 0; continue }
            var s: Float = 0
            for c in 0..<channels { s += data[c][offset + i] }
            mono[i] = s * scale
        }

        let step = max(1, n / 64)
        let wave = stride(from: 0, to: n, by: step).prefix(64).map { mono[$0] }

        for i in 0..<size { mono[i] *= window[i] }
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                mono.withUnsafeBufferPointer { mp in
                    mp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(size / 2))
            }
        }

        var bars = [Float](repeating: 0, count: bands)
        for b in 0..<bands {
            let lo = edges[b], hi = max(edges[b + 1], lo + 1)
            var peak: Float = 0
            for i in lo..<min(hi, size / 2) where mags[i] > peak { peak = mags[i] }
            let amplitude = sqrt(peak) * 2 / Float(size)
            let db = 20 * log10(max(amplitude, 1e-7))
            bars[b] = max(0, min(1, (db + 66) / 60))
        }
        return (bars, wave)
    }
}
