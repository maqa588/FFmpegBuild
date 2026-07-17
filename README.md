<h1 align="center">FFmpegBuild</h1>

<p align="center">
  <b>Slim FFmpeg xcframeworks for Apple platforms.</b><br>
  Demux, decode, and a thin HLS-fMP4 mux path for AVPlayer bridging. No network stack, no CLI binaries.
</p>

<p align="center">
  <a href="https://github.com/superuser404notfound/FFmpegBuild/releases/latest"><img src="https://img.shields.io/github/v/release/superuser404notfound/FFmpegBuild?label=release&color=blue"></a>
  <a href="https://swiftpackageindex.com/superuser404notfound/FFmpegBuild"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fsuperuser404notfound%2FFFmpegBuild%2Fbadge%3Ftype%3Dswift-versions"></a>
  <a href="https://swiftpackageindex.com/superuser404notfound/FFmpegBuild"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fsuperuser404notfound%2FFFmpegBuild%2Fbadge%3Ftype%3Dplatforms"></a>
  <img src="https://img.shields.io/badge/FFmpeg-8.1-brightgreen">
  <img src="https://img.shields.io/badge/dav1d-1.5.1-blue">
  <img src="https://img.shields.io/badge/license-LGPL--2.1-lightgrey">
  <a href="https://ko-fi.com/superuser404"><img src="https://img.shields.io/badge/Ko--fi-Support-FF5E5B?logo=kofi&logoColor=white"></a>
</p>

---

## Why

Full FFmpeg builds for iOS land at 40-70 MB because they bundle a TLS stack, encoders, filters, and a dozen protocols your app will never use. For a player, most of that is dead weight. Apple already ships HTTP/3, `URLSession`, `Network.framework`, VideoToolbox and AVFoundation. So this build strips out everything you don't need and keeps what you do.

**~10 MB per architecture, zero network dependencies, one build script.**

## In

| Library        | What it does                                          |
| -------------- | ----------------------------------------------------- |
| libavformat    | Demux MKV, MP4, WebM, MPEG-TS, MPEG-PS (VOB / DVD), AVI, OGG, FLV, plus raw elementary streams |
| libavcodec     | Decode video + audio (with VideoToolbox bridge)       |
| libavutil      | Shared primitives                                     |
| libswresample  | Audio resampling / channel remap / format convert     |
| libswscale     | Pixel-format convert (YUV → NV12 / P010) for the SW-decode path |
| **dav1d**      | Fast AV1 software decoder (separate xcframework)      |

## Out

Anything the app layer should already handle or doesn't need:

- Network / TLS: FFmpeg reads from an `avio_alloc_context` callback, you wire `URLSession` to it
- Encoders, except FLAC and EAC3 (kept for the audio bridge that re-encodes non-streamable sources like TrueHD / DTS / DTS-HD MA. FLAC for the lossless 7.1 path, EAC3 5.1 for the default soundbar-compat path that surfaces surround via HDMI bitstream tunnel)
- Muxers, except MP4 / MOV / HLS (kept for the HLS-fMP4 producer that wraps streams for AVPlayer)
- libavdevice and libavfilter
- All FFmpeg filters, including zscale/tonemap/deinterlacers; zimg is not built
- DVB Teletext via libzvbi; text and bitmap subtitles already handled by the app remain enabled
- Programs (`ffmpeg`, `ffplay`, `ffprobe`)
- Hardware accel layers other than VideoToolbox
- Text subtitle rendering (do that in SwiftUI)
- iOS Simulator and all tvOS targets

## Build

```sh
./build.sh          # iOS arm64 + macOS universal, dynamic frameworks
./build.sh static   # static variant, for apps that can meet LGPL 6(a) themselves
./build.sh package  # repackage frameworks without recompiling
./build.sh clean    # wipe everything
```

Needs Xcode 16+, Meson, Ninja, pkg-config and NASM. Only FFmpeg and dav1d are fetched. The script builds iOS arm64 plus macOS arm64/x86_64.

Output lands in `Sources/` as xcframeworks, ready to consume via Swift Package Manager. The shipped xcframeworks contain **dynamic frameworks** (dylib-in-framework, `@rpath` install names); Xcode embeds and signs them in the app bundle automatically when you link the package. That is what keeps the LGPL relink requirement satisfiable for closed-source apps, see License below.

## Use

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/superuser404notfound/FFmpegBuild", from: "1.0.0")
]

// Target:
.product(name: "FFmpegBuild", package: "FFmpegBuild")
```

Pin `branch: "main"` instead of a version if you want to track the latest rebuilds (that is how [AetherEngine](https://github.com/superuser404notfound/AetherEngine) consumes it).

Then import the modules you need: `Libavformat`, `Libavcodec`, `Libavutil`, `Libswresample`, `Libswscale`, `Libdav1d`. The umbrella `FFmpegBuild` product links all of them plus the system frameworks (AudioToolbox, CoreMedia, CoreVideo, VideoToolbox) in one shot.

## Decoder support

- **Video (hardware via VideoToolbox)**: H.264, HEVC up to Main10 (HDR10 / DV Profile 8)
- **Video (software)**: AV1 (dav1d), VP9, VP8, MPEG-2, MPEG-4, VC-1
- **Audio**: AAC, AC3, EAC3 (incl. JOC detection for Atmos), FLAC, MP2, MP3, Opus, Vorbis, TrueHD, MLP, DTS, ALAC, PCM (incl. Blu-ray LPCM via `pcm_bluray`)
- **Subtitles**: SRT, ASS, SSA, WebVTT, PGS, DVB, DVD

HDR metadata (BT.2020, SMPTE ST 2084 / PQ, HLG, DV RPU) is preserved end-to-end so the decode pipeline can tag frames correctly.

## Size

Release configuration, dynamic framework binaries as embedded in the app:

| Target                            | FFmpeg    | dav1d    | Total     |
| --------------------------------- | --------- | -------- | --------- |
| iOS arm64                         | measured after each build | measured after each build | see build output |
| macOS universal (arm64 + x86_64)  | ~18.1 MB  | ~2.4 MB  | ~20.5 MB  |

Assembly-optimized paths are enabled where the Apple toolchain permits.

## Built with

This package is vibe-coded, assembled and maintained by [Vincent Herbst](https://github.com/superuser404notfound) in close pair-programming with **Claude** (Anthropic). The commit log is the receipt: nearly every commit carries a `Co-Authored-By: Claude` trailer.

## License

**LGPL-2.1-or-later** ([LICENSE](LICENSE)), matching upstream FFmpeg's default license. The build explicitly passes `--disable-gpl`, `--disable-version3` and `--disable-nonfree`; libavfilter, zimg and libzvbi are not built. Per component:

| Component | License |
| --- | --- |
| FFmpeg (five libraries) | LGPL-2.1-or-later |
| dav1d | BSD-2-Clause |
| Build scripts / SPM stubs (this repo) | LGPL-2.1-or-later |

All shipped third-party license texts live in [LICENSES/](LICENSES/).

### Shipping in an App Store app

The xcframeworks are dynamic frameworks on purpose: LGPL section 6 requires that end users can swap in a modified version of the library. With dynamic linking your app binary stays yours (closed source is fine) and the obligations reduce to:

1. Link the package normally; Xcode embeds the frameworks in `YourApp.app/Frameworks/`. Do not merge them into the app binary (no mergeable-library trickery), that would recreate static linking.
2. Reproduce the license texts from [LICENSES/](LICENSES/) somewhere reasonable (acknowledgements screen, bundled file).
3. State that your app uses FFmpeg and friends, and link to the source of the exact build you ship (a tagged release of this repo, or your fork if you modified it).

If you build the `static` variant instead, those steps are not sufficient: LGPL 6(a) then requires you to provide your app's object files (or full source) so users can relink. That is realistic for open-source apps and rarely anything else, which is why static is not the shipped shape.

---

<p align="center"><sub>Used by <a href="https://github.com/superuser404notfound/AetherEngine">AetherEngine</a>.</sub></p>
