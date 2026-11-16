import AVFoundation
import Foundation

/// `Singer --probe <files…>`: prints metadata and runs a muted engine playback check.
/// Handy for checking whether a file will play without opening the UI.
enum Probe {
    static func run(_ paths: [String]) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for path in paths {
                let url = URL(fileURLWithPath: path)
                let t = await MetadataLoader.load(Track(url: url))
                print("== \(url.lastPathComponent)")
                print("   title=\(t.title) artist=\(t.artist ?? "-") album=\(t.album ?? "-")")
                print("   codec=\(t.codec) \(t.sampleRate)Hz \(t.channels)ch \(t.bitsPerSample)bit \(t.bitrateKbps)kbps lossless=\(t.isLossless) duration=\(String(format: "%.2f", t.duration))s")
                for c in t.chapters { print("   chapter \(c.index + 1): \(c.title) @ \(formatTime(c.start))") }
                await playCheck(t)
            }
            done.signal()
        }
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    @MainActor
    private static func playCheck(_ t: Track) async {
        do {
            var url = t.url
            if !AudioFormats.isNative(t.ext) { url = try await FFmpegDecoder.decode(url) }
            let engine = AudioEngine()
            engine.volume = 0
            var frames = 0
            engine.onVisual = { bars, _ in if bars.contains(where: { $0 > 0 }) { frames += 1 } }
            try engine.load(url: url)
            engine.play()
            try await Task.sleep(for: .seconds(0.6))
            let t1 = engine.currentTime
            engine.seek(to: engine.duration / 2)
            try await Task.sleep(for: .seconds(0.4))
            let t2 = engine.currentTime
            engine.stop()
            print(String(format: "   play OK: t=%.2fs, after seek to %.2fs → t=%.2fs, visual frames=%d",
                         t1, engine.duration / 2, t2, frames))
        } catch {
            print("   play FAILED: \(error.localizedDescription)")
        }
    }
}

import SwiftUI

/// `Singer --snapshot out.png [files…]`: renders the main + EQ panels offscreen (dev aid).
enum Snapshot {
    @MainActor
    static func run(_ args: [String]) {
        guard let out = args.first else { return }
        let model = PlayerModel.shared
        if args.count > 1 {
            model.clear()
            model.add(urls: args.dropFirst().map { URL(fileURLWithPath: $0) }, playFirst: true)
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        }
        let view = VStack(spacing: 0) { MainPanel(); EqualizerPanel() }
            .frame(width: 480)
            .environment(model)
            .preferredColorScheme(.dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: out))
        print("wrote \(out)")
    }
}

/// `Singer --probe-sound a b hires`: gapless handover a → b, then output-rate switching to `hires` and back.
enum SoundProbe {
    @MainActor
    static func run(_ paths: [String]) {
        guard paths.count >= 3 else { print("usage: --probe-sound a b hires"); return }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let engine = AudioEngine()
        engine.volume = 0
        engine.bassBoost = 9
        engine.clipGuard = true
        engine.voiceBoost = 6
        let start = Date()
        var advancedAt: Double?, finishedAt: Double?
        engine.onAdvanced = { advancedAt = Date().timeIntervalSince(start) }
        engine.onFinished = { finishedAt = Date().timeIntervalSince(start) }
        func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        do {
            try engine.load(url: urls[0])
            let d0 = engine.duration
            engine.play()
            print("gapless queued:", engine.queueNext(url: urls[1]))
            var maxBefore = 0.0, minAfter = 99.0
            while finishedAt == nil, Date().timeIntervalSince(start) < d0 * 2 + 5 {
                wait(0.05)
                let t = engine.currentTime
                if advancedAt == nil { maxBefore = max(maxBefore, t) } else { minAfter = min(minAfter, t) }
            }
            print(String(format: "file A %.2fs; advanced at %.2fs (A reached %.2fs, B started at %.2fs); finished at %.2fs",
                         d0, advancedAt ?? -1, maxBefore, minAfter, finishedAt ?? -1))

            let dev = OutputDevice.defaultDevice!
            print("device rate before:", OutputDevice.nominalRate(dev))
            try engine.load(url: urls[2]); engine.play(); wait(1)
            print(String(format: "hires file → device %.0f, engine output %.0f, t=%.2f", OutputDevice.nominalRate(dev), engine.outputSampleRate, engine.currentTime))
            try engine.load(url: urls[0]); engine.play(); wait(1)
            print(String(format: "44.1k file → device %.0f, engine output %.0f, t=%.2f", OutputDevice.nominalRate(dev), engine.outputSampleRate, engine.currentTime))
            engine.stop()
        } catch {
            print("FAILED:", error)
        }
        OutputDevice.restoreOriginal()
        if let dev = OutputDevice.defaultDevice { print("device rate restored:", OutputDevice.nominalRate(dev)) }
    }
}
