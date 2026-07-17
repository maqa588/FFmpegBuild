// FFmpegBuild: Minimal FFmpeg for Apple platforms.
//
// This is a thin wrapper target that links the prebuilt xcframeworks
// (Libavcodec, Libavformat, Libavutil, Libswresample, Libswscale) together
// with dav1d and
// the required system frameworks (VideoToolbox, AudioToolbox, etc).
//
// The xcframeworks are built by build.sh from FFmpeg source with a
// minimal configuration: demuxing, decoding, selected mux/encode support,
// no network/TLS, no filters, and no programs.
//
// Usage: import FFmpegBuild (or the individual Libav* modules)
import Foundation
