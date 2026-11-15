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
