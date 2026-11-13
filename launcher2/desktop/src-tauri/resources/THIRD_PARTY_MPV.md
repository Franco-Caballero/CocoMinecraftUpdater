# Bundled media engine

Coco runs mpv as a separate process, controlled through its documented JSON IPC
protocol and embedded into an owned Windows child surface. mpv and its bundled
FFmpeg/libplacebo libraries provide their own audio/video decoders; they do not
install system codecs or change Windows file associations.

- mpv v0.42.0-11-g8bc468896, upstream https://github.com/mpv-player/mpv
- Windows x86_64 build (baseline, not AVX2/v3):
  https://github.com/shinchiro/mpv-winbuild-cmake/releases/tag/20261109
- Build recipes and dependency source definitions:
  https://github.com/shinchiro/mpv-winbuild-cmake
- mpv corresponding source: https://github.com/mpv-player/mpv/tree/8bc468896e
- FFmpeg corresponding source: https://github.com/FFmpeg/FFmpeg/tree/0f89d936b
- mpv licensing: https://github.com/mpv-player/mpv/blob/8bc468896e/Copyright
- GPL v2: https://www.gnu.org/licenses/old-licenses/gpl-2.0.html
- GPL v3: https://www.gnu.org/licenses/gpl-3.0.html
- FFmpeg legal information: https://ffmpeg.org/legal.html

Upstream mpv/MPlayer/FFmpeg/libplacebo and dependency authors retain their
copyrights and licenses. The unmodified upstream Windows runtime is distributed
with Coco; Coco's small input script is separate. Runtime files are pinned by
SHA-256 in Get-Coco2PlayerRuntime.ps1 and services/native_player.rs. Source and
build recipe URLs identify the corresponding upstream work, not a code-signing
claim. The executable is not described as Authenticode-signed.
