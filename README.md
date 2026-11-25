<p align="center">
  <img src=".github/EasyCapViewer_icon.png" alt="EasyCapViewer Icon" width="128" height="128">
</p>

<h1 align="center">EasyCapViewer</h1>

<p align="center">
  <strong>Capture live video and audio from USB analog capture dongles on macOS</strong>
</p>

<p align="center">
  <img src=".github/EasyCapViewer_preview.gif" alt="EasyCapViewer Preview">
</p>

<p align="center">
  <a href="#features">Features</a> &middot;
  <a href="#supported-hardware">Hardware</a> &middot;
  <a href="#installation">Installation</a> &middot;
  <a href="#usage">Usage</a> &middot;
  <a href="#building">Building</a> &middot;
  <a href="#license">License</a>
</p>

---

## Overview

**EasyCapViewer** is a native macOS application for capturing live video and audio from inexpensive USB analog capture dongles — the kind commonly known as "EasyCap" devices. These compact USB devices accept composite (RCA) or S-Video input from analog sources like VCRs, camcorders, security cameras, and game consoles, and convert them to digital video streams.

Built in Objective-C and Swift, EasyCapViewer provides real-time Metal-rendered video preview, configurable deinterlacing, recording to QuickTime movies via AVFoundation, and a dark HUD-style control interface.

---

## Features

### Video Capture
- **Real-time preview** via Metal texture rendering
- **Composite and S-Video** input selection
- **NTSC, PAL, and SECAM** video standards (10 format variants)
- **7 deinterlacing modes**: Progressive, Weave, Line Double HQ/LQ, Alternate, Blur, Drop

### Video Processing
- **Aspect ratio** presets: 4:3, 16:10, 16:9 (and custom)
- **Interactive cropping** with draggable handles and border trimming
- **Brightness, contrast, saturation, and hue** adjustments (device-dependent)
- **Integer scaling**: Half, Actual, and Double size
- **Full-screen mode** with auto-hiding cursor
- **Frame drop indicator** when the system can't keep up

### Audio
- **Live audio monitoring** through system speakers
- **Volume control** with mute toggle
- **Mono-to-stereo upconversion** for devices that output mono audio
- **Audio input selection** from any connected CoreAudio device

### Recording
- **QuickTime .mov** export via AVFoundation with codec and quality selection
- **Frame rate conversion** for recording at different rates than capture
- **Hardware-accelerated codecs**: H.264, HEVC, Motion JPEG, ProRes

### Interface
- **Dark HUD overlay** controls that blend with the video
- **Unified single-window layout** with settings and error log sidebars
- **SwiftUI settings panel** for all video, audio, and image parameters
- **Error log window** with color-coded, timestamped messages
- **Localization** infrastructure (English included)

---

## Supported Hardware

| Chipset | Device Examples | Status |
|---------|----------------|--------|
| **Syntek STK1160** | EasyCap DC60, various generic dongles | Supported |
| **Empia EM2860** | EM2860-based capture devices | Supported |
| **Somagic** | Somagic EasyCap variants | Supported |
| **Fushicai** | Fushicai UTV007 devices | Supported |

| Input | Connector |
|-------|-----------|
| **Composite Video** | RCA jack (yellow) |
| **S-Video** | Mini-DIN 4-pin |
| **Stereo Audio** | RCA jacks (red/white) — device-dependent |

---

## Installation

### Requirements

- **macOS 13.0** (Ventura) or later
- A supported USB capture device
- An analog video source (VCR, camera, console, etc.)

### Download

Pre-built binaries are not yet available. To use EasyCapViewer, build from source using the instructions below.

---

## Usage

1. **Connect** your USB capture device to a USB port
2. **Launch** EasyCapViewer — it automatically detects connected devices
3. **Plug in** your video source (composite or S-Video cable)
4. Click **Play** in the menu bar or press **Space** to start capture
5. Use **Cmd+,** to open the settings panel and adjust video/audio parameters

### Keyboard Shortcuts

| Key | Action |
|-----|--------|
| Space | Toggle play/pause |
| Cmd+F | Toggle full screen |
| Cmd+T | Toggle float on top |
| Cmd+S | Start recording |
| Cmd+. | Stop recording |
| Cmd+Up/Down | Adjust volume |
| Cmd+Opt+Up/Down | Toggle mute |

---

## Architecture

EasyCapViewer uses a **producer-consumer pipeline** with a single-window SwiftUI/AppKit hybrid interface:

```
USB Hardware → ECVCaptureDevice (Metal rendering via MTKView)
                    ↓
              ECVVideoStorage + Deinterlacing
                    ↓
              ECVCaptureSession → fans out to:
                    ├── MainWindowController (video + settings sidebar + error log sidebar)
                    ├── ECVAudioTarget (CoreAudio speakers)
                    └── ECVMovieRecorder (AVFoundation .mov export)
```

Key design: `NSDocument`-based architecture with `@Observable` SwiftUI views for settings, error log, and welcome screen. Metal handles video rendering; AppKit handles interactive crop/play overlays. Thread safety via `ECVReadWriteLock` (pthread_rwlock).

For detailed file-level architecture, see [`AGENTS.md`](AGENTS.md).

---

## Building

### Prerequisites

- **Xcode** with macOS 13+ SDK
- **macOS Ventura** or later (for running)

### Build Commands

```bash
# Debug build
xcodebuild -project EasyCapViewer.xcodeproj \
           -scheme EasyCapViewer \
           -configuration Debug build

# Release build
xcodebuild -project EasyCapViewer.xcodeproj \
           -scheme EasyCapViewer \
           -configuration Release build

# Clean
xcodebuild -project EasyCapViewer.xcodeproj \
           -scheme EasyCapViewer clean
```

### Build Settings

| Setting | Value |
|---------|-------|
| Deployment Target | macOS 13.0 |
| Architecture | Universal (arm64 + x86_64) |
| ARC | Enabled |
| Hardened Runtime | Enabled |
| Sandboxing | Disabled (IOKit USB access required) |

---

## Privacy & Security

- EasyCapViewer accesses USB hardware directly via IOKit, which **cannot run in a sandboxed environment**
- No data is sent to any remote server
- No analytics or telemetry
- Recording creates local .mov files only

---

## License

**BSD 2-Clause License** — Copyright (c) 2009-2013, Ben Trask. All rights reserved.

See [`LICENSE`](LICENSE) for the full license text. Individual source files may contain the original license header.

---

## Credits

[Original Version by Ben Trask](https://github.com/btrask/EasyCapViewer) (2009-2013).

## Headless STK1160 diagnostics

`tools/ecv-capture.m` uses the existing USB driver and frame decoder without a
window, keyboard events, or the Metal renderer. It currently supports **video
snapshots and diagnostics only** for USB `05e1:0408`. The separate native audio
recorder below captures PCM audio; synchronized movie recording is not yet supported
by these tools. It builds using Apple's Command Line Tools;
full Xcode is not required for this tool.

```sh
python3 tools/build-headless.py
# Close the GUI first: only one process can own the USB capture interface.
build/headless/ecv-capture --standard pal --input composite --seconds 5 \
  --output build/headless/frame.uyvy > build/headless/status.json
```

Capture starts immediately and stops after the requested duration (or SIGINT /
SIGTERM). Options include `pal`, `ntsc`, `secam` and `composite`, `svideo`, or
composite channels `1`–`4`. The default is PAL composite for five seconds. Each
invocation opens and resets the adapter. It requires an active analog source.

Standard output is JSON: frame callback count, dimensions, packed UYVY pixel
format, luminance statistics, and decoder registers sampled at callback 30.
`sync_locked` is null if no status sample was obtained; otherwise it reflects
bit 6 of SAA711x register `0x1f` (clear means sync locked). This interpretation
follows the [Linux SAA711x driver](https://github.com/torvalds/linux/blob/master/drivers/media/i2c/saa7115.c);
raw values are retained for clone-chip debugging. A stream of USB frames does
**not** by itself prove that the analog source is connected or synchronized.
The frame count measures callbacks, not unique interlaced frames or dropped frames.

Diagnostics go to stderr. Exit status is 0 if frames arrived, 1 for capture or
output failure, and 2 for invalid arguments. A dark or unlocked picture still
returns 0; inspect JSON to assess the signal. The output is the last woven frame,
without timestamps or audio. Convert a PAL snapshot using FFmpeg:

```sh
ffmpeg -f rawvideo -pixel_format uyvy422 -video_size 704x576 \
  -i build/headless/frame.uyvy -frames:v 1 build/headless/frame.png
```

Use the JSON dimensions for other standards (NTSC is 704×480). Build output and
local captures under `build/` are ignored by Git.

For the GUI, automatic playback is already supported and can be enabled with:

```sh
defaults write com.christian-sanches.EasyCapViewer ECVAutoPlay -bool true
```

That setting starts playback on the next device connection or app launch; it
does not turn the GUI application into a headless process.

For hardware diagnosis, `--decoder-input 0|1|2|3` overrides only the low nibble
of decoder register `0x02`, selecting another analog pin inside the SAA711x.
This differs from `--input 1|2|3|4`, which selects the dongle's external input
multiplexer. Omit the override for normal capture. It is applied during device
initialization and does not change the GUI driver or its defaults. Some inputs
may produce no frames, in which case the frame-triggered status sample is absent.


### Confirmed Samsung VP-L500 cabling (2026-11-25)

These connections were tested with this camera, this four-contact cable, and the
Syntek `05e1:0408` adapter. They are not a universal Samsung socket pinout.

| Camera cable RCA plug | Capture adapter input | Observed result |
| --- | --- | --- |
| White | Yellow composite video | Recognizable PAL playback picture |
| Red | White audio | Soundtrack confirmed by listening |
| Yellow | Disconnected | Not needed |

The cable's measured contacts, from tip, are Audio 1 / Audio 2 / Video / Ground;
its RCA colors do not match their actual function on this camera. Keep the
mini-jack fully inserted in AV OUT. The captured soundtrack appeared in PCM
channel **2** (zero-based `c1`), despite using the adapter's white socket.

### Native headless audio capture

The initial FFmpeg 9.0.1 AVFoundation test yielded only 7.48 seconds of PCM during
a 10-second capture, and listening revealed clicks. Its
[AVFoundation input implementation](https://github.com/FFmpeg/FFmpeg/blob/n9.0.1/libavdevice/avfoundation.m)
replaces an unread audio buffer when a new callback arrives. This is a suspected
capture-loss cause, not proof that every audible click originates there.

`ecv-audio` writes PCM directly from each serial AVFoundation callback into a CAF
file, preserving both channels and reporting timestamp discontinuities. No noise
removal, gap filling, or resampling is applied to the original recording. Disk
write failures and gaps cause a nonzero exit status, rather than silently claiming
a clean recording. Gaps below two samples are treated as timestamp rounding.

```sh
python3 tools/build-headless.py
build/headless/ecv-audio 'USB Audio Interface' 10 build/headless/take-01.caf \
  > build/headless/take-01-audio.json
# Export the confirmed audio channel for listening (keep the original CAF):
ffmpeg -i build/headless/take-01.caf -af 'pan=mono|c0=c1' \
  -c:a pcm_s16le build/headless/take-01-mono.wav
```

Use a new output filename for every capture; the recorder refuses to overwrite.
SIGINT/SIGTERM finalize the file. Duration is wall time after session startup;
compare `sample_seconds` with `timeline_seconds` to assess sample continuity.
The adapter can be tested with the player stopped, but a playback/listening test
is still needed to assess clicks. Audio and video tools currently run independently;
this is not yet a synchronized movie recorder.

A recognizable video picture was captured while decoder register `0x1f` reported
`0x48` (the generic `sync_locked` diagnostic was false). Do not use that flag alone
to reject a recording on this adapter; clone-chip interpretation and video timing
still need investigation with playback running.

Validation on this adapter: native audio alone recorded 480,085 sample frames
(10.001771 s), and audio with concurrent USB video capture recorded 479,980
(9.999583 s). Both timelines matched the sample durations with zero detected
gaps. The concurrent video test delivered 498 callbacks and reported decoder
status `0x81` (locked). These tests establish continuity, not audible quality;
a fresh tape playback test is required to confirm the clicks are resolved.
