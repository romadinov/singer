# Singer

A Winamp-style audio player for macOS, written in SwiftUI on AVAudioEngine.

## Formats

| Native (Core Audio)                             | Via ffmpeg (if installed)                |
|-------------------------------------------------|------------------------------------------|
| MP3, AAC/M4A, **M4B** (with chapters), MP4      | APE, WavPack (.wv), TTA, TAK             |
| **FLAC**, **ALAC** (.m4a), WAV, AIFF, CAF       | DSD (.dsf/.dff), Ogg Vorbis, Opus, WMA   |

Files that need ffmpeg get decoded once into `~/Library/Caches/Singer/decoded`: lossless sources go to FLAC so they stay bit-exact, lossy ones to float CAF. Then they play like any native file. Install ffmpeg with `brew install ffmpeg`.

## Features

- Classic main window: LCD time (click it to toggle elapsed/remaining), scrolling title, kbps/kHz/bit-depth, LOSSLESS badge, spectrum or oscilloscope visualizer (click to cycle), volume, balance
- 10-band equalizer (60 Hz – 16 kHz) with preamp, presets and a curve preview
- Playlist: drag & drop files or folders, M3U/M3U8 load and save, sort, reorder, crop. It's restored on launch.
- Audiobooks: M4B/MP4 chapters (chapter list, seek-bar ticks, `[` `]` to skip), resume position for long files, speed 0.5×–3× with pitch kept
- Media keys and Now Playing in Control Center
- Follows output device changes (AirPods, headphones) without stopping

## Keys

| Key | Action | Key | Action |
|---|---|---|---|
| Z | Previous | ⌘← / ⌘→ | Seek ±10 s |
| X | Play | ⇧⌘← / ⇧⌘→ | Seek ±1 min |
| C / Space | Pause | ⌘↑ / ⌘↓ | Volume |
| V | Stop | [ / ] | Prev / next chapter |
| B | Next | S / R | Shuffle / repeat |
| ⌘O | Add files | ⌥G / ⌥E | Toggle EQ / playlist |

## Build

```bash
scripts/build-app.sh            # → build/Singer.app
scripts/build-app.sh --install  # also copy to /Applications
open build/Singer.app
```

Requires macOS 15+ and Xcode / Swift 6.

Dev aids: `swift run Singer --probe file…` prints metadata and runs a muted playback and seek check. `--snapshot out.png file…` renders the panels offscreen. It replaces the saved playlist with the given files.
