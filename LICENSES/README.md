# Third-party licenses

FFmpegBuild's shipped xcframeworks aggregate the following components. Apps
that distribute these frameworks must reproduce the applicable license texts
(for example on an acknowledgements screen or in bundled documentation).

| Component | Frameworks | License | Text |
| --- | --- | --- | --- |
| FFmpeg (libavcodec, libavformat, libavutil, libswresample, libswscale) | `Libavcodec`, `Libavformat`, `Libavutil`, `Libswresample`, `Libswscale` | LGPL-2.1-or-later | [LGPL-2.1.txt](LGPL-2.1.txt) |
| dav1d | `Libdav1d` | BSD-2-Clause | [dav1d.BSD-2-Clause.txt](dav1d.BSD-2-Clause.txt) |

Notes:

- FFmpeg is explicitly configured with `--disable-gpl`, `--disable-version3`
  and `--disable-nonfree`, so the FFmpeg portions are LGPL-2.1-or-later.
- libavfilter, zimg and libzvbi are disabled and are not fetched, compiled,
  packaged or distributed by this fork.
- No other patches are applied to any upstream source.
