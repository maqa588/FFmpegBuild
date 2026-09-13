#!/bin/zsh
#
# FFmpegBuild: Minimal FFmpeg cross-compilation for Apple platforms.
# Includes dav1d (fast AV1 software decoder).
#
# Usage:
#   ./build.sh          # Build iOS arm64 + macOS universal dynamic frameworks
#   ./build.sh static   # Build static variant (not App Store friendly for closed-source apps)
#   ./build.sh package  # Repackage frameworks from existing build products
#   ./build.sh clean    # Remove all build artifacts
#
set -eo pipefail  # pipefail so `... | tail -N` doesn't swallow configure/make errors

FFMPEG_VERSION="n8.1.2"
FFMPEG_REPO="https://github.com/FFmpeg/FFmpeg.git"
DAV1D_VERSION="1.5.4"
DAV1D_REPO="https://code.videolan.org/videolan/dav1d.git"
SCRIPT_DIR="${0:a:h}"
BUILD_DIR="${SCRIPT_DIR}/build"
OUTPUT_DIR="${SCRIPT_DIR}/Sources"
FFMPEG_SRC="${BUILD_DIR}/ffmpeg-src"
DAV1D_SRC="${BUILD_DIR}/dav1d-src"

# Dynamic (dylib-in-framework) is the shipped shape: LGPL requires that end
# users can swap the FFmpeg libraries, which embedded dynamic frameworks
# permit and a statically linked closed-source binary does not. Static stays
# available for people who build themselves and can meet LGPL 6(a) instead.
MODE="build"
LINKAGE="dynamic"
for ARG in "$@"; do
    case "${ARG}" in
        clean)   MODE="clean" ;;
        package) MODE="package" ;;
        static)  LINKAGE="static" ;;
        dynamic) LINKAGE="dynamic" ;;
        *) echo "Unknown argument: ${ARG}"; exit 1 ;;
    esac
done

require_tool() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing required tool: $1"
        exit 1
    }
}

if [[ "${MODE}" != "clean" ]]; then
    for TOOL in xcrun lipo xcodebuild install_name_tool codesign; do
        require_tool "${TOOL}"
    done
fi
if [[ "${MODE}" == "build" ]]; then
    for TOOL in git meson ninja pkg-config make; do
        require_tool "${TOOL}"
    done
fi

if [[ "${LINKAGE}" == "static" ]]; then
    CONFIGURE_LINK_FLAGS=(--enable-static --disable-shared)
    MESON_LIBRARY="static"
else
    CONFIGURE_LINK_FLAGS=(--disable-static --enable-shared)
    MESON_LIBRARY="shared"
fi

# ─────────────────────────────────────────────────────────

discard_stale_source() {
    # The fetch functions below skip the clone when the source directory already exists, so
    # bumping a version string alone would rebuild the OLD source and produce a release that
    # changed nothing. Drop a tree whose checked-out tag is not the one asked for and let the
    # caller re-clone. Verified against the shallow `--depth 1 --branch <tag>` clones these
    # functions create: `describe --tags --exact-match` returns the tag on each of them.
    local dir="$1" want="$2" have
    [[ -d "${dir}" ]] || return 0
    have="$(git -C "${dir}" describe --tags --exact-match 2>/dev/null)"
    if [[ "${have}" != "${want}" ]]; then
        echo "→ ${dir:t} is at '${have:-unknown}', want '${want}': discarding and re-cloning"
        rm -rf "${dir}"
    fi
}

fetch_ffmpeg() {
    discard_stale_source "${FFMPEG_SRC}" "${FFMPEG_VERSION}"
    if [[ -d "${FFMPEG_SRC}" ]]; then
        echo "→ FFmpeg source already exists, skipping clone"
        return
    fi
    echo "→ Cloning FFmpeg ${FFMPEG_VERSION}..."
    git clone --depth 1 --branch "${FFMPEG_VERSION}" "${FFMPEG_REPO}" "${FFMPEG_SRC}"
}

patch_ffmpeg_pgssub() {
    # AetherEngine #142, second shape (FFmpeg PR 23851). PGS carries no end time,
    # a cue is closed by the start of its successor, so dropping a damaged display
    # set also removes the successor that would have closed the previous cue: the
    # predecessor overstays its authored end until the next intact set arrives.
    # Outside AV_EF_EXPLODE, emit the empty subtitle instead. The pts is already
    # set and no rect has been allocated yet, so this is the same clearing form
    # the object_count == 0 path a few lines above returns.
    local F="${FFMPEG_SRC}/libavcodec/pgssubdec.c"
    grep -q "pgs-missing-palette" "${F}" && return
    echo "→ Patching FFmpeg: close the predecessor cue on a missing pgssub palette (AetherEngine #142)"
    perl -0777 -pi -e '
s#               ctx->presentation\.palette_id\);\n        avsubtitle_free\(sub\);\n        return AVERROR_INVALIDDATA;\n    \}#               ctx->presentation.palette_id);\n        /* pgs-missing-palette: dropping the set here would also drop the successor\n         * that closes the previous cue, so the predecessor overstays its authored\n         * end. Outside AV_EF_EXPLODE emit the empty subtitle instead: the pts is\n         * set, no rect is allocated yet, and this is the clearing form the\n         * object_count == 0 path above returns.\n         * See FFmpegBuild build.sh patch_ffmpeg_pgssub (AetherEngine issue 142,\n         * FFmpeg PR 23851). */\n        if (avctx->err_recognition \& AV_EF_EXPLODE) {\n            avsubtitle_free(sub);\n            return AVERROR_INVALIDDATA;\n        }\n        av_freep(\&sub->rects);\n        return 1;\n    }#;
' "${F}"
    if ! grep -q "pgs-missing-palette" "${F}"; then
        echo "ERROR: pgssubdec missing-palette patch did not apply (upstream source changed?)"
        exit 1
    fi
}

patch_ffmpeg_visionos() {
    # visionOS has no OpenGL and no OpenGL ES, so kCVPixelBufferOpenGLESCompatibilityKey
    # is marked unavailable there. Upstream picks that key on TARGET_OS_IPHONE, which is 1
    # on visionOS (TARGET_OS_IOS is the one that is 0), so the hardware-decode path fails
    # to compile for xros with "'kCVPixelBufferOpenGLESCompatibilityKey' is unavailable".
    # Nothing is lost by omitting it: the attribute only asks CoreVideo to make the buffer
    # bindable as a GL texture, and on visionOS every consumer is Metal, which the
    # IOSurface backing set just above already covers. TARGET_OS_VISION is defined as 0 on
    # SDKs that predate it, and an undefined macro evaluates to 0 in #if, so this is safe
    # on every other slice.
    local F="${FFMPEG_SRC}/libavcodec/videotoolbox.c"
    grep -q "TARGET_OS_VISION" "${F}" && return
    echo "→ Patching FFmpeg: skip the OpenGL ES buffer attribute on visionOS"
    perl -0777 -pi -e '
s@\#if TARGET_OS_IPHONE\n    CFDictionarySetValue\(buffer_attributes, kCVPixelBufferOpenGLESCompatibilityKey, kCFBooleanTrue\);\n\#else@\#if TARGET_OS_VISION\n    /* visionOS has neither OpenGL ES nor OpenGL, and the key is unavailable there.\n     * Consumers are Metal, which the IOSurface properties above already cover.\n     * See FFmpegBuild build.sh patch_ffmpeg_visionos. */\n\#elif TARGET_OS_IPHONE\n    CFDictionarySetValue(buffer_attributes, kCVPixelBufferOpenGLESCompatibilityKey, kCFBooleanTrue);\n\#else@;
' "${F}"
    if ! grep -q "TARGET_OS_VISION" "${F}"; then
        echo "ERROR: visionOS videotoolbox patch did not apply (upstream source changed?)"
        exit 1
    fi
}

patch_ffmpeg_matroska_tts() {
    # AetherEngine #145, reworked after upstream review (FFmpeg PR 23852):
    # RFC 9559 (11.1.3, 11.2, 5.1.3.5.3) puts Block/SimpleBlock relative
    # timestamps and BlockDuration in Track Ticks, so absolute time is
    # (cluster + rel x TTS) x TimestampScale, and upstream matroskadec
    # implements exactly that. The earlier clamp here (any TTS != 1 forced to
    # 1.0) rested on a wrong reading of the RFC and would mistime a conformant
    # TTS != 1 file; the file that motivated it was authored on the segment
    # axis (invalid per RFC). What remains worth carrying: TTS != 1 is
    # deprecated (maxver 3), many readers ignore it, and a file carrying it may
    # have been authored against such readers. Emit a warning next to
    # upstream's own "< 0.01" guard so the condition is visible; timestamp
    # behavior stays RFC.
    local F="${FFMPEG_SRC}/libavformat/matroskadec.c"
    grep -q "AetherEngine issue 145" "${F}" && return
    echo "→ Patching FFmpeg: warn on matroska TrackTimestampScale != 1 (AetherEngine #145)"
    perl -0777 -pi -e '
s#        if \(track->time_scale < 0\.01\) \{\n            av_log\(matroska->ctx, AV_LOG_WARNING,\n                   "Track TimestampScale too small %f, assuming 1\.0\.\\n",\n                   track->time_scale\);\n            track->time_scale = 1\.0;\n        \}#        if (track->time_scale < 0.01) {\n            av_log(matroska->ctx, AV_LOG_WARNING,\n                   "Track TimestampScale too small %f, assuming 1.0.\\n",\n                   track->time_scale);\n            track->time_scale = 1.0;\n        } else if (track->time_scale != 1.0) {\n            /* Applied per RFC 9559: block timestamps and BlockDuration are\n             * Track Ticks, scaled against the segment axis. The element is\n             * deprecated (maxver 3) and many readers ignore it, so a file\n             * carrying it may have been authored against such readers; surface\n             * it instead of staying silent. See FFmpegBuild build.sh\n             * patch_ffmpeg_matroska_tts (AetherEngine issue 145). */\n            av_log(matroska->ctx, AV_LOG_WARNING,\n                   "TrackTimestampScale %f applied per RFC 9559; many readers "\n                   "ignore this element and files may be authored against them.\\n",\n                   track->time_scale);\n        }#;
' "${F}"
    if ! grep -q "AetherEngine issue 145" "${F}"; then
        echo "ERROR: matroska TrackTimestampScale patch did not apply (upstream source changed?)"
        exit 1
    fi
}

fetch_dav1d() {
    discard_stale_source "${DAV1D_SRC}" "${DAV1D_VERSION}"
    if [[ -d "${DAV1D_SRC}" ]]; then
        echo "→ dav1d source already exists, skipping clone"
        return
    fi
    echo "→ Cloning dav1d ${DAV1D_VERSION}..."
    git clone --depth 1 --branch "${DAV1D_VERSION}" "${DAV1D_REPO}" "${DAV1D_SRC}"
}

# ─────────────────────────────────────────────────────────
# dav1d cross-compilation (Meson + Ninja)
# ─────────────────────────────────────────────────────────

build_dav1d_one() {
    local KEY="$1" SDK="$2" ARCH="$3" TARGET="$4" MIN_VER="$5"

    echo ""
    echo "━━━ Building dav1d: ${KEY} (${ARCH} for ${SDK}) ━━━"

    local SDK_PATH=$(xcrun --sdk "${SDK}" --show-sdk-path)
    local INSTALL_DIR="${BUILD_DIR}/dav1d-thin/${KEY}"
    local WORK_DIR="${BUILD_DIR}/dav1d-work/${KEY}"
    rm -rf "${WORK_DIR}" "${INSTALL_DIR}"
    mkdir -p "${WORK_DIR}" "${INSTALL_DIR}"

    # Determine CPU family and system for Meson cross file
    local CPU_FAMILY="aarch64"
    local CPU="aarch64"
    [[ "${ARCH}" == "x86_64" ]] && CPU_FAMILY="x86_64" && CPU="x86_64"

    local SYSTEM="darwin"

    # Create Meson cross file
    cat > "${WORK_DIR}/cross.txt" << CROSSEOF
[binaries]
c = '/usr/bin/clang'
ar = '/usr/bin/ar'
strip = '/usr/bin/strip'

[built-in options]
c_args = ['-arch', '${ARCH}', '-isysroot', '${SDK_PATH}', '-target', '${TARGET}', '-fno-common']
c_link_args = ['-arch', '${ARCH}', '-isysroot', '${SDK_PATH}', '-target', '${TARGET}', '-Wl,-headerpad_max_install_names']

[host_machine]
system = '${SYSTEM}'
cpu_family = '${CPU_FAMILY}'
cpu = '${CPU}'
endian = 'little'
CROSSEOF

    cd "${WORK_DIR}"

    meson setup \
        --cross-file "${WORK_DIR}/cross.txt" \
        --prefix="${INSTALL_DIR}" \
        --default-library="${MESON_LIBRARY}" \
        --buildtype=release \
        -Denable_tools=false \
        -Denable_examples=false \
        -Denable_tests=false \
        "${DAV1D_SRC}" \
        2>&1 | tail -5

    ninja -j$(sysctl -n hw.ncpu) 2>&1 | tail -3
    ninja install 2>&1 | tail -3

    echo "✓ dav1d ${KEY} → ${INSTALL_DIR}"
}

# ─────────────────────────────────────────────────────────
# FFmpeg
# ─────────────────────────────────────────────────────────

COMMON_FLAGS=(
    --enable-pic
    --enable-optimizations --enable-stripping --disable-debug
    --disable-gpl --disable-version3 --disable-nonfree
    --disable-autodetect --disable-doc --disable-programs
    --disable-devices --disable-outdevs --disable-indevs
    --disable-avdevice --disable-avfilter
    --enable-swscale --disable-encoders --disable-muxers
    --disable-bsfs --disable-network --disable-protocols
    --disable-d3d11va --disable-dxva2 --disable-vaapi --disable-vdpau
    --disable-gray --disable-iconv --disable-bzlib
    --disable-linux-perf --disable-symver --disable-swscale-alpha
    --enable-avcodec --enable-avformat --enable-avutil --enable-swresample
    --disable-libzimg --disable-libzvbi
    --enable-videotoolbox --enable-audiotoolbox
    --enable-libdav1d
    --enable-protocol=file --enable-protocol=pipe --enable-protocol=data
    # concat is deliberately NOT enabled. It is a script demuxer: a file beginning with
    # "ffconcat version 1.0" makes libavformat open the paths listed inside it through the
    # file protocol. Nothing here asks for it by name, so probing was the only way to reach
    # it, and that made any byte stream a potential file-open primitive. hls and dash stay in:
    # they are a documented capability of this package (README) and consumers rely on them.
    --disable-demuxers
    # dash is NOT enabled: its demuxer needs libxml2, which this build does not link, so
    # configure answered `Disabled dash_demuxer because not all dependencies are satisfied`
    # and the flag silently did nothing. Asking for it again without libxml2 would only
    # restore that false impression. DASH content still arrives through mov/mpegts segments.
    --enable-demuxer=hls --enable-demuxer=matroska
    --enable-demuxer=mov --enable-demuxer=mpegts --enable-demuxer=mpegps
    --enable-demuxer=avi --enable-demuxer=flv --enable-demuxer=h264
    # asf: native .wmv / .asf. Enabled together with the whole WMA decoder family
    # below and never without it, see the block there. Unlike the concat demuxer
    # removed above this is a plain media demuxer, no file-open primitive.
    --enable-demuxer=asf
    --enable-demuxer=hevc --enable-demuxer=aac --enable-demuxer=ac3
    --enable-demuxer=eac3 --enable-demuxer=flac --enable-demuxer=ogg
    --enable-demuxer=wav --enable-demuxer=mp3 --enable-demuxer=srt
    --enable-demuxer=ass --enable-demuxer=data
    # sup: raw PGS/SUP sidecar files (Jellyfin serves external PGS tracks as raw .sup streams;
    # the pgssub DECODER was always in, but without this demuxer avformat_open_input rejects the
    # file with AVERROR_INVALIDDATA and external PGS subtitles never load. AetherEngine sidecar path.)
    --enable-demuxer=sup
    # webvtt: standalone .vtt sidecar files. The webvtt DECODER was always in (it serves WebVTT
    # tracks inside Matroska and HLS, where those demuxers supply the stream), but without this
    # demuxer avformat_open_input rejects a .vtt file with AVERROR_INVALIDDATA and an external
    # WebVTT subtitle never loads. Same shape as the sup case above. It also carries the cue
    # settings: the demuxer attaches line/position/align to each packet as
    # AV_PKT_DATA_WEBVTT_SETTINGS, which is the only path they take (the decoder drops them).
    --enable-demuxer=webvtt
    # Raw MPEG-1/2 and MPEG-4 video elementary-stream demuxers. The mpegps
    # (MPEG Program Stream / DVD VOB) demuxer carries no codec signaling, so
    # it tags a 0x1E0-0x1EF video stream as request_probe and confirms the
    # codec via these raw demuxers' probe functions. Without them MPEG-2
    # video in a Program Stream is never confirmed (the lenient mp3 demuxer
    # probe wins instead) and no video stream is exposed: DVD-Video ISO
    # playback shows audio only. The h264/hevc raw demuxers above already
    # cover H.264/HEVC-in-PS; these add MPEG-2 (DVD) and MPEG-4 Part 2.
    --enable-demuxer=mpegvideo --enable-demuxer=m4v
    --disable-decoders
    --enable-decoder=h264 --enable-decoder=hevc --enable-decoder=vp8
    --enable-decoder=vp9 --enable-decoder=av1 --enable-decoder=libdav1d
    --enable-decoder=mpeg2video --enable-decoder=mpeg4 --enable-decoder=vc1
    --enable-decoder=qtrle
    # Legacy Microsoft video, the MPEG-4-family tail that pre-2005 AVI rips and
    # WMV-era remuxes still carry (FFmpegBuild#3). All are native libavcodec
    # decoders under FFmpeg's LGPL-2.1-or-later terms: no external library, no GPL
    # flag. msmpeg4v1/v2/v3 and wmv1/wmv2 share the msmpeg4dec object, so once v3
    # (MS-MPEG4 v3 / "DivX 3.11", the reported case) is in, its siblings cost their
    # decoder structs plus wmv2dsp; wmv3 (WMV9) selects the already-enabled
    # vc1_decoder and adds little beyond its own registration. Without them
    # avcodec_find_decoder returns nil and AetherEngine's software path fails the
    # load with unsupportedCodec, because since FFmpegBuild#1 the routing default is
    # software for everything the native path does not carry. The avi demuxer above
    # is already enabled, so the AVI case is complete with the decoder alone.
    --enable-decoder=msmpeg4v1 --enable-decoder=msmpeg4v2 --enable-decoder=msmpeg4v3
    --enable-decoder=wmv1 --enable-decoder=wmv2 --enable-decoder=wmv3
    # Flash Video, the legacy half. The flv DEMUXER has been on the list above since
    # the beginning, so a modern .flv (H.264 + AAC, everything after 2008) already
    # direct-plays; what was missing is the decoder tail of the Flash era. FLV1 is
    # Sorenson Spark, the H.263 variant of every pre-2008 file, and it shares the
    # h263 / mpeg4 objects already compiled in; vp6 / vp6a / vp6f are the On2 family
    # Flash 8 brought and pay for the vp56 core once. Note the registered name: the
    # FLV1 decoder answers to `flv`, which is also what configure wants here, so a
    # consumer asking for `flv1` by name finds nothing (AetherEngine dispatches by
    # id and does not care).
    #
    # Flash Screen Video (flashsv / flashsv2) is deliberately out: it needs zlib,
    # which --disable-autodetect above switches off, so the flag would be dropped
    # without a word, exactly like the dash demuxer. Screen recordings are also not
    # what a film library holds. Enabling it means --enable-zlib and counting the
    # generated decoder list afterwards, not adding a flag.
    --enable-decoder=flv --enable-decoder=vp6 --enable-decoder=vp6a --enable-decoder=vp6f
    # Windows Media audio, the whole family, which is what makes the native .wmv /
    # .asf case complete: demuxer above, video decoders on the line above this one,
    # sound here. #3 closed the other way in August 2026 on the reporter's answer
    # that their library holds WMV only inside Matroska and MPEG-TS; a second field
    # report in September 2026 said the native form does turn up, so the boundary
    # moved rather than the argument.
    #
    # All five, not the two a .wmv usually carries, because this chain is
    # all-or-nothing by construction. A decoder left out here is a file that plays
    # SILENTLY: AetherEngine's audio bridge asks libavcodec for a decoder by id, that
    # lookup returns nothing, and the session falls to video-only, which reads as a
    # playback bug where an honest unsupported-format error would not. Measured
    # 2026-09-10 with a codec this build omits: `AudioBridge: no FFmpeg decoder for
    # source codec id 69633 ... falling back to SILENT video-only`. Note the level:
    # the host's routing table is NOT what decides this, a codec it does not name
    # still plays as long as the decoder is here, so the promise is made in this
    # file and nowhere else. wmav1 / wmav2 are WMA
    # Standard, wmapro is WMA 9/10 Pro and the usual audio of anything post-2003,
    # wmalossless and wmavoice are rare in film content and cost tens of KB between
    # them, which is less than one silent-audio report costs. WMA is not fMP4-legal,
    # so AetherEngine's AudioBridge decodes and re-encodes it, same as MP2 and
    # Blu-ray LPCM below. DecoderAvailabilityTests refuses a half set from here on.
    --enable-decoder=wmav1 --enable-decoder=wmav2 --enable-decoder=wmapro
    --enable-decoder=wmalossless --enable-decoder=wmavoice
    --enable-decoder=aac --enable-decoder=aac_latm --enable-decoder=ac3
    --enable-decoder=eac3 --enable-decoder=flac --enable-decoder=mp3
    --enable-decoder=mp3float --enable-decoder=opus --enable-decoder=vorbis
    --enable-decoder=truehd --enable-decoder=mlp --enable-decoder=dca --enable-decoder=alac
    --enable-decoder=pcm_s16le --enable-decoder=pcm_s24le --enable-decoder=pcm_f32le
    # Flash Video audio, the whole tail, all-or-nothing for the same reason the WMA
    # family above is: a decoder missing here is a file that plays as a silent film
    # rather than failing honestly, because the bridge has nothing to open. Nellymoser Asao and ADPCM-SWF are what the
    # Flash era recorded, speex is its voice codec (native decoder, no libspeex),
    # and FLV's PCM shapes are big-endian S16, unsigned 8-bit and G.711 A-law /
    # mu-law, none of which the little-endian line above carries. None is fMP4-legal,
    # so every one of them goes through AudioBridge. Tens of KB between them.
    --enable-decoder=nellymoser --enable-decoder=adpcm_swf --enable-decoder=speex
    --enable-decoder=pcm_s16be --enable-decoder=pcm_u8
    --enable-decoder=pcm_alaw --enable-decoder=pcm_mulaw
    # Blu-ray LPCM (PCM_BLURAY): M2TS audio tracks that ship raw LPCM. Not
    # legal in fMP4, so AetherEngine's AudioBridge decodes to PCM and
    # re-encodes; without the decoder those tracks are silent. Prep for
    # Blu-ray ISO support (Phase 2); harmless for everything else.
    --enable-decoder=pcm_bluray
    # MP2 (MPEG-1 Layer II) decoder for DVD-remux audio tracks that
    # still carry MP2. Not legal in fMP4 so AetherEngine's AudioBridge
    # decodes to PCM and re-encodes as FLAC. ~5 KB binary cost.
    --enable-decoder=mp2
    --enable-decoder=ass --enable-decoder=srt --enable-decoder=subrip
    --enable-decoder=movtext --enable-decoder=dvdsub --enable-decoder=dvbsub
    --enable-decoder=pgssub --enable-decoder=webvtt
    --disable-parsers
    --enable-parser=aac --enable-parser=aac_latm --enable-parser=ac3
    --enable-parser=flac --enable-parser=h264 --enable-parser=hevc
    --enable-parser=mpegaudio --enable-parser=mpeg4video
    --enable-parser=mpegvideo --enable-parser=opus --enable-parser=vorbis
    --enable-parser=vp8 --enable-parser=vp9 --enable-parser=av1
    # dca parser coalesces a DTS core frame and the following DTS-HD extension
    # substream (EXSS) into one packet. Without it, the MPEG-TS demuxer hands the
    # decoder the core (0x7FFE8001) and the EXSS (0x64582025) as SEPARATE packets,
    # so a DTS-HD MA EXSS arrives with no core and the decoder rejects every frame
    # with "Residual encoded channels are present without core" (silent audio on
    # Blu-ray M2TS; AetherEngine #64). Matroska is unaffected (its blocks are
    # already whole frames), which is why only the .m2ts path was silent.
    --enable-parser=dca
    # Same framing-completeness class as dca, for the other enabled decoders whose
    # frames the MPEG-TS / MPEG-PS demuxer can only deliver correctly with a parser:
    #   mlp  -> TrueHD / MLP (common on Blu-ray M2TS; the AudioBridge decodes it).
    #           Without it, TrueHD access units mis-frame exactly like DTS-HD MA did.
    #   vc1  -> VC-1 video (Blu-ray, WMV); the software decode path needs framed BDUs.
    #   dvbsub / dvdsub -> DVB (live TS) and DVD (Program Stream / VOB) bitmap subtitles.
    #           Defensive: matches a stock FFmpeg build so live-TV / DVD subtitle
    #           framing is correct rather than relying on PES-aligned delivery.
    --enable-parser=mlp --enable-parser=vc1
    --enable-parser=dvbsub --enable-parser=dvdsub
    --enable-bsf=aac_adtstoasc --enable-bsf=h264_mp4toannexb
    --enable-bsf=hevc_mp4toannexb --enable-bsf=extract_extradata
    # dca_core extracts the mandatory DTS core substream from a DTS-HD
    # (MA / HRA) packet at the bitstream level. AetherEngine's AudioBridge
    # runs DTS through it before decode so the lossless XLL extension (which
    # residual-codes channels and can fail to reconstruct standalone) is
    # dropped up front; the bridge re-encodes lossy anyway. Yields clean
    # full-rate 5.1/7.1 core PCM on every frame (AetherEngine #64).
    --enable-bsf=dca_core
    # MP4 / mov muxers underlie the per-fragment fmp4 segment output;
    # the hls muxer drives the segmentation + per-segment styp emission
    # + playlist for AetherEngine's HLSVideoEngine. We override
    # `s->io_open` / `s->io_close2` so segment writes land in Swift
    # memory rather than on disk, but the muxer's logic itself is
    # libavformat's hlsenc.c verbatim, byte-identical to
    # `ffmpeg -f hls -hls_segment_type fmp4`.
    --enable-muxer=mp4 --enable-muxer=mov --enable-muxer=hls
    # FLAC encoder kept for stereo / lossless paths and CLI tools.
    --enable-encoder=flac
    # EAC3 encoder for the multichannel bridge. AVPlayer decodes FLAC
    # to LPCM and routes that through the active HDMI port's channel
    # count — most consumer soundbars (Sonos Arc and equivalents)
    # accept multichannel only via bitstream codecs (EAC3, AC3, DD+,
    # Atmos), not LPCM, so a 7.1 FLAC track gets downmixed to stereo
    # at the route. EAC3 5.1 bridges that gap: AVPlayer hands the
    # encoded bitstream to HDMI, the sink decodes its own 5.1 mix,
    # surround works on every device that decodes EAC3 (which is
    # essentially every modern AVR + soundbar). Trade-off: lossy
    # (~384 kbps for 5.1) versus the FLAC bridge's lossless, but
    # Some playback routes do not expose LPCM-side audio passthrough, so the
    # lossless stream is not necessarily delivered as multichannel output.
    --enable-encoder=eac3
)

build_one() {
    local KEY="$1" SDK="$2" ARCH="$3" TARGET="$4" MIN_VER="$5"

    echo ""
    echo "━━━ Building FFmpeg: ${KEY} (${ARCH} for ${SDK}) ━━━"

    local SDK_PATH=$(xcrun --sdk "${SDK}" --show-sdk-path)
    local INSTALL_DIR="${BUILD_DIR}/thin/${KEY}"
    local DAV1D_DIR="${BUILD_DIR}/dav1d-thin/${KEY}"
    rm -rf "${INSTALL_DIR}"
    mkdir -p "${INSTALL_DIR}"

    local CFLAGS="-arch ${ARCH} -isysroot ${SDK_PATH} -target ${TARGET} -fno-common -DHAVE_FORK=0"
    local LDFLAGS="-arch ${ARCH} -isysroot ${SDK_PATH} -target ${TARGET} -Wl,-headerpad_max_install_names"

    # Add dav1d include/lib paths
    CFLAGS="${CFLAGS} -I${DAV1D_DIR}/include"
    LDFLAGS="${LDFLAGS} -L${DAV1D_DIR}/lib"

    local ASM_FLAGS=(--enable-neon)
    [[ "${ARCH}" == "x86_64" ]] && ASM_FLAGS=(--disable-asm --disable-neon)

    local WORK_DIR="${BUILD_DIR}/work/${KEY}"
    rm -rf "${WORK_DIR}"
    mkdir -p "${WORK_DIR}"
    cd "${WORK_DIR}"

    # Set pkg-config path so FFmpeg's configure can find dav1d
    export PKG_CONFIG_PATH="${DAV1D_DIR}/lib/pkgconfig"

    "${FFMPEG_SRC}/configure" \
        --prefix="${INSTALL_DIR}" \
        --enable-cross-compile \
        --target-os=darwin \
        --arch="${ARCH}" \
        --cc="/usr/bin/clang" \
        --extra-cflags="${CFLAGS}" \
        --extra-ldflags="${LDFLAGS}" \
        "${ASM_FLAGS[@]}" \
        "${CONFIGURE_LINK_FLAGS[@]}" \
        "${COMMON_FLAGS[@]}" \
        2>&1 | tail -5

    make -j$(sysctl -n hw.ncpu) 2>&1 | tail -3
    make install 2>&1 | tail -3

    echo "✓ FFmpeg ${KEY} → ${INSTALL_DIR}"
}

# The compilers record absolute build-directory install names (FFmpeg,
# libtool) or bare @rpath dylib names (meson). Rewrite the binary's own id
# and every reference to a sibling library to @rpath framework paths so the
# frameworks resolve when embedded in an app bundle.
fix_install_names() {
    local BIN="$1" FW="$2" PLATFORM="$3"

    local SUBPATH="${FW}.framework/${FW}"
    [[ "${PLATFORM}" == "macos" ]] && SUBPATH="${FW}.framework/Versions/A/${FW}"
    install_name_tool -id "@rpath/${SUBPATH}" "${BIN}"

    local PAIRS=(
        "libavcodec:Libavcodec" "libavformat:Libavformat" "libavutil:Libavutil"
        "libswresample:Libswresample" "libswscale:Libswscale"
        "libdav1d:Libdav1d"
    )
    local DEPS
    DEPS=(${(f)"$(otool -L "${BIN}" | awk 'NR>1 {print $1}')"})
    local DEP PAIR NAME TARGET_FW NEW
    for DEP in "${DEPS[@]}"; do
        local BASE="${DEP##*/}"
        for PAIR in "${PAIRS[@]}"; do
            NAME="${PAIR%%:*}"
            TARGET_FW="${PAIR##*:}"
            if [[ "${BASE}" == ${NAME}.dylib || "${BASE}" == ${NAME}.*.dylib ]]; then
                NEW="${TARGET_FW}.framework/${TARGET_FW}"
                [[ "${PLATFORM}" == "macos" ]] && NEW="${TARGET_FW}.framework/Versions/A/${TARGET_FW}"
                install_name_tool -change "${DEP}" "@rpath/${NEW}" "${BIN}"
            fi
        done
    done
}

make_framework() {
    local LIB="$1" FW="$2" PLATFORM="$3"
    shift 3
    local KEYS=("$@")

    local FW_DIR="${BUILD_DIR}/frameworks/${PLATFORM}/${FW}.framework"
    rm -rf "${FW_DIR}"
    mkdir -p "${FW_DIR}/Headers" "${FW_DIR}/Modules"

    # Headers from first arch
    local HEADER_SRC="${BUILD_DIR}/thin/${KEYS[1]}/include/${LIB}"
    # For dav1d, headers are in a different location
    [[ "${LIB}" == "dav1d" ]] && HEADER_SRC="${BUILD_DIR}/dav1d-thin/${KEYS[1]}/include/dav1d"

    if [[ -d "${HEADER_SRC}" ]]; then
        cp -R "${HEADER_SRC}/"* "${FW_DIR}/Headers/"
    fi

    # Rewrite cross-framework includes so Clang resolves them on case-sensitive filesystems
    for SIBLING in libavcodec libavformat libavutil libswresample libswscale; do
        local UPPER="Lib${SIBLING:3}"
        LC_ALL=C sed -i "" -E "s|(#include[[:space:]]*\")${SIBLING}/|\\1${UPPER}/|g" \
            "${FW_DIR}/Headers/"*.h 2>/dev/null || true
    done

    # Remove platform-specific hwcontext headers (FFmpeg only)
    if [[ "${LIB}" == lib* ]]; then
        rm -f "${FW_DIR}/Headers/hwcontext_amf.h" \
              "${FW_DIR}/Headers/hwcontext_cuda.h" \
              "${FW_DIR}/Headers/hwcontext_d3d11va.h" \
              "${FW_DIR}/Headers/hwcontext_d3d12va.h" \
              "${FW_DIR}/Headers/hwcontext_drm.h" \
              "${FW_DIR}/Headers/hwcontext_dxva2.h" \
              "${FW_DIR}/Headers/hwcontext_mediacodec.h" \
              "${FW_DIR}/Headers/hwcontext_oh.h" \
              "${FW_DIR}/Headers/hwcontext_opencl.h" \
              "${FW_DIR}/Headers/hwcontext_qsv.h" \
              "${FW_DIR}/Headers/hwcontext_vaapi.h" \
              "${FW_DIR}/Headers/hwcontext_vdpau.h" \
              "${FW_DIR}/Headers/hwcontext_vulkan.h"
    fi

    # Lipo
    local EXT="a"
    [[ "${LINKAGE}" == "dynamic" ]] && EXT="dylib"
    local INPUTS=()
    for K in "${KEYS[@]}"; do
        local LIB_PATH
        if [[ "${LIB}" == "dav1d" ]]; then
            LIB_PATH="${BUILD_DIR}/dav1d-thin/${K}/lib/libdav1d.${EXT}"
        else
            LIB_PATH="${BUILD_DIR}/thin/${K}/lib/${LIB}.${EXT}"
        fi
        INPUTS+=("${LIB_PATH}")
    done
    lipo -create "${INPUTS[@]}" -output "${FW_DIR}/${FW}"

    if [[ "${LINKAGE}" == "dynamic" ]]; then
        fix_install_names "${FW_DIR}/${FW}" "${FW}" "${PLATFORM}"
        strip -x "${FW_DIR}/${FW}" 2>/dev/null || true
    fi

    # Module map
    cat > "${FW_DIR}/Modules/module.modulemap" << EOF
framework module ${FW} [system] {
    umbrella "."
    exclude header "d3d11va.h"
    exclude header "d3d12va.h"
    exclude header "dxva2.h"
    exclude header "qsv.h"
    exclude header "vdpau.h"
    export *
}
EOF
    # Info.plist: App Store submission rejects bundles missing
    # CFBundleShortVersionString or MinimumOSVersion (ITMS-90057,
    # ITMS-90360), and ALSO rejects when an embedded framework's
    # MinimumOSVersion is *lower* than the host app's deployment
    # target (ITMS-90208). These floors match Strophe's deployment targets.
    local MIN_OS SUPPORTED_PLATFORM
    case "${PLATFORM}" in
        ios)   MIN_OS="16.0"; SUPPORTED_PLATFORM="iPhoneOS" ;;
        macos) MIN_OS="13.0"; SUPPORTED_PLATFORM="MacOSX" ;;
        *)     echo "Unsupported framework platform: ${PLATFORM}"; return 1 ;;
    esac

    cat > "${FW_DIR}/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>${FW}</string>
<key>CFBundleIdentifier</key><string>com.aetherengine.${FW}</string>
<key>CFBundleName</key><string>${FW}</string>
<key>CFBundleVersion</key><string>1.0</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>${SUPPORTED_PLATFORM}</string></array>
<key>MinimumOSVersion</key><string>${MIN_OS}</string>
</dict></plist>
EOF

    # macOS requires the versioned ("deep") framework bundle layout, with the
    # binary/Headers/Modules under Versions/A and Info.plist in
    # Versions/A/Resources. iOS uses shallow bundles (everything at the
    # root), which is what we built above. Restructure only the macOS
    # framework, otherwise Xcode 15+/26 rejects it during embedded-framework
    # validation: "contains Info.plist, expected
    # Versions/Current/Resources/Info.plist since the platform does not use
    # shallow bundles".
    if [[ "${PLATFORM}" == "macos" ]]; then
        local V="${FW_DIR}/Versions/A"
        mkdir -p "${V}/Resources"
        mv "${FW_DIR}/${FW}"      "${V}/${FW}"
        mv "${FW_DIR}/Headers"    "${V}/Headers"
        mv "${FW_DIR}/Modules"    "${V}/Modules"
        mv "${FW_DIR}/Info.plist" "${V}/Resources/Info.plist"
        ln -s "A"                          "${FW_DIR}/Versions/Current"
        ln -s "Versions/Current/${FW}"     "${FW_DIR}/${FW}"
        ln -s "Versions/Current/Headers"   "${FW_DIR}/Headers"
        ln -s "Versions/Current/Modules"   "${FW_DIR}/Modules"
        ln -s "Versions/Current/Resources" "${FW_DIR}/Resources"
    fi

    # install_name_tool and strip invalidate the linker's ad-hoc signature;
    # re-sign so the dylibs stay loadable (Xcode re-signs on embed anyway).
    if [[ "${LINKAGE}" == "dynamic" ]]; then
        codesign --force --sign - "${FW_DIR}"
    fi
}

make_xcframeworks() {
    echo ""
    echo "━━━ Creating XCFrameworks ━━━"

    local PAIRS=("libavcodec:Libavcodec" "libavformat:Libavformat" "libavutil:Libavutil" "libswresample:Libswresample" "libswscale:Libswscale" "dav1d:Libdav1d")

    for PAIR in "${PAIRS[@]}"; do
        local LIB="${PAIR%%:*}"
        local FW="${PAIR##*:}"

        make_framework "$LIB" "$FW" "ios"          ios-arm64
        make_framework "$LIB" "$FW" "macos"        macos-arm64 macos-x86_64

        local XCF="${OUTPUT_DIR}/${FW}.xcframework"
        rm -rf "${XCF}"

        echo "  → ${FW}.xcframework"
        xcodebuild -create-xcframework \
            -framework "${BUILD_DIR}/frameworks/ios/${FW}.framework" \
            -framework "${BUILD_DIR}/frameworks/macos/${FW}.framework" \
            -output "${XCF}" 2>&1 | tail -1
        echo "  ✓ ${FW}.xcframework"
    done
}

# ─────────────────────────────────────────────────────────

if [[ "${MODE}" == "clean" ]]; then
    echo "Cleaning..."
    rm -rf "${BUILD_DIR}" "${OUTPUT_DIR}/"*.xcframework
    echo "✓ Clean"
    exit 0
fi

# `package` mode skips fetch + compile and only re-runs the
# framework + xcframework packaging steps using whatever's already
# in build/thin and build/dav1d-thin. Useful when the only change
# is to header-exclusion lists or framework Info.plist values, so
# we don't burn a full multi-arch FFmpeg rebuild. Pass the same
# linkage argument the compile ran with.
if [[ "${MODE}" == "package" ]]; then
    rm -rf "${BUILD_DIR}/frameworks" "${OUTPUT_DIR}/"*.xcframework 2>/dev/null || true
    make_xcframeworks
    echo ""
    echo "✓ Repackage complete (${LINKAGE})"
    exit 0
fi

echo "╔══════════════════════════════════════╗"
echo "║  FFmpegBuild: FFmpeg + dav1d (AV1)  ║"
echo "║  VideoToolbox HW + Metal ready      ║"
echo "║  Linkage: ${LINKAGE}                     ║"
echo "╚══════════════════════════════════════╝"

fetch_ffmpeg
patch_ffmpeg_pgssub
patch_ffmpeg_visionos
patch_ffmpeg_matroska_tts
fetch_dav1d

# Build dav1d for the three supported architecture targets first.
build_dav1d_one ios-arm64          iphoneos         arm64  arm64-apple-ios16.0                    16.0
build_dav1d_one macos-arm64        macosx           arm64  arm64-apple-macos13.0                  13.0
build_dav1d_one macos-x86_64       macosx           x86_64 x86_64-apple-macos13.0                 13.0

# Build FFmpeg (links against dav1d)
build_one ios-arm64          iphoneos         arm64  arm64-apple-ios16.0                    16.0
build_one macos-arm64        macosx           arm64  arm64-apple-macos13.0                  13.0
build_one macos-x86_64       macosx           x86_64 x86_64-apple-macos13.0                 13.0

make_xcframeworks

echo ""
echo "╔══════════════════════════════════════╗"
echo "║  ✓ Build complete!                   ║"
echo "╚══════════════════════════════════════╝"
echo ""
echo "Sizes:"
for xcf in "${OUTPUT_DIR}"/*.xcframework; do
    [[ -d "$xcf" ]] && echo "  $(du -sh "$xcf" | cut -f1)  $(basename $xcf)"
done
