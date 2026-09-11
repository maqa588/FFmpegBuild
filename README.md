<p align="center">
  <h1 align="center">FFmpegBuild</h1>
  <p align="center">
    <strong>Minimal, modular, modern FFmpeg for Apple platforms</strong>
  </p>
  <p align="center">
    iOS 16+ &bull; macOS 13+
  </p>
  <p align="center">
    <a href="https://swiftpackageindex.com/superuser404notfound/FFmpegBuild"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fsuperuser404notfound%2FFFmpegBuild%2Fbadge%3Ftype%3Dswift-versions"></a>
    <a href="https://swiftpackageindex.com/superuser404notfound/FFmpegBuild"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fsuperuser404notfound%2FFFmpegBuild%2Fbadge%3Ftype%3Dplatforms"></a>
    <img src="https://img.shields.io/badge/FFmpeg-8.1-brightgreen">
    <img src="https://img.shields.io/badge/dav1d-1.5.4-blue">
    <img src="https://img.shields.io/badge/license-LGPL--2.1-lightgrey">
    <a href="https://ko-fi.com/superuser404"><img src="https://img.shields.io/badge/Ko--fi-Support-FF5E5B?logo=kofi&logoColor=white"></a>
  </p>
</p>

---

Full FFmpeg builds for iOS land at 40-70 MB and link every codec known to man. Most apps need a fraction of that: demuxing modern containers, feeding hardware decoders via VideoToolbox, software fallbacks for formats Apple doesn't support natively (AV1, VP9, DTS, TrueHD, FLAC), and bitstream filters.

FFmpegBuild provides **prebuilt XCFrameworks** with a minimal surface area designed for media player apps.

## In

| Library        | What it does                                          |
| -------------- | ----------------------------------------------------- |
| libavformat    | Demux MKV, MP4, WebM, MPEG-TS, MPEG-PS (VOB / DVD), HLS, AVI, ASF / WMV, OGG, FLV, SUP, WebVTT, plus raw elementary streams |
| libavcodec     | Decode video + audio (with VideoToolbox bridge)       |
| libavutil      | Shared primitives                                     |
| libswresample  | Audio resampling / channel remap / format convert     |
| libswscale     | Pixel-format convert (YUV → NV12 / P010) for the SW-decode path |
| **dav1d**      | Fast AV1 software decoder (separate xcframework)      |

## Out

Anything the app layer should already handle, or that pulls in bloat:

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

## Usage

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/superuser404notfound/FFmpegBuild", from: "1.0.0")
]

// Target:
.product(name: "FFmpegBuild", package: "FFmpegBuild")
```

Pin `branch: "main"` instead of a version if you want to track the latest rebuilds.

Then import the modules you need: `Libavformat`, `Libavcodec`, `Libavutil`, `Libswresample`, `Libswscale`, `Libdav1d`. The umbrella `FFmpegBuild` product links all of them plus the system frameworks (AudioToolbox, CoreMedia, CoreVideo, VideoToolbox) in one shot.

## Decoder support

- **Video (hardware via VideoToolbox)**: H.264, HEVC up to Main10 (HDR10 / DV Profile 8)
- **Video (software)**: AV1 (dav1d), VP9, VP8, MPEG-2, MPEG-4, VC-1, QuickTime RLE (qtrle), and the legacy Microsoft tail: MS-MPEG4 v1 / v2 / v3 (DivX 3.x in pre-2005 AVI rips), WMV1 / WMV2, WMV3 (WMV9). A native `.wmv` / `.asf` plays whole: the `asf` demuxer and every WMA decoder ship with it. The Flash tail is here: FLV1 (Sorenson Spark) and On2 VP6 / VP6F / VP6A with the era's audio, so a legacy `.flv` plays whole where before only H.264-in-FLV did. Flash Screen Video stays out (requires zlib).
- **Audio**: AAC, AC3, EAC3 (incl. JOC detection for Atmos), FLAC, MP2, MP3, Opus, Vorbis, TrueHD, MLP, DTS, ALAC, PCM (incl. Blu-ray LPCM via `pcm_bluray`, G.711 A-law / mu-law, big-endian and unsigned 8-bit), WMA Standard / Pro / Lossless / Voice, Nellymoser Asao, ADPCM-SWF, Speex
- **Subtitles**: SRT, ASS, SSA, WebVTT, PGS, DVB, DVD

HDR metadata (BT.2020, SMPTE ST 2084 / PQ, HLG, DV RPU) is preserved end-to-end so the decode pipeline can tag frames correctly.

## Size

Release configuration, dynamic framework binaries as embedded in the app:

| Target                            | FFmpeg    | dav1d    | Total     |
| --------------------------------- | --------- | -------- | --------- |
| iOS arm64                         | measured after each build | measured after each build | see build output |
| macOS universal (arm64 + x86_64)  | ~18.1 MB  | ~2.4 MB  | ~20.5 MB  |

Assembly-optimized paths are enabled where the Apple toolchain permits.

## Local FFmpeg patches

`build.sh` applies small patches to the FFmpeg source after checkout:

- **`patch_ffmpeg_pgssub`**: closes the predecessor cue on a missing pgssub palette (AetherEngine issue 142, FFmpeg PR 23851).
- **`patch_ffmpeg_visionos`**: `videotoolbox.c` skips `kCVPixelBufferOpenGLESCompatibilityKey` on visionOS, where OpenGL ES is unavailable.
- **`patch_ffmpeg_matroska_tts`**: `matroskadec.c` logs a warning when a Matroska track carries a `TrackTimestampScale` other than 1.0 (AetherEngine issue 145, FFmpeg PR 23852).

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

FFmpegBuild ships under **LGPL 2.1**. Apple's App Store allows LGPL dynamic frameworks as long as the user's right to reverse-engineer and re-link the LGPL portions is preserved.

1. Distribute your app as usual with FFmpegBuild embedded as **dynamic frameworks** (the default `build.sh` output). Do not use static linkage for closed-source App Store builds.
2. Provide a copy of the [LGPL 2.1 license](LICENSES/LGPL-2.1.txt) in your app's acknowledgements / legal screen.
3. Keep the build scripts reproducible (they are, via this repo) so users can build replacement binaries for their own use.
