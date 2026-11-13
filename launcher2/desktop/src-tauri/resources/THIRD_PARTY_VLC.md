# Bundled libVLC decoder

Coco uses unmodified libVLC 3.0.24 dynamically, from the official VideoLAN
Windows x64 package. It does not install VLC as an application, change file
associations, install system codecs, or load the user's VLC configuration.

Video is decoded into RGBA memory and copied to a WebView2 shared buffer. The
canvas and Coco's controls use the same compositor; no native child window can
cover controls, tooltips or cut baked subtitles. Movies remain unchanged.

- Official package: https://download.videolan.org/pub/videolan/vlc/3.0.24/win64/vlc-3.0.24-win64.7z
- SHA-256: 1ed59c09152e78aff84663fa76efab26057716576db74332858810e5ef54ae1f
- Corresponding source: https://download.videolan.org/pub/videolan/vlc/3.0.24/vlc-3.0.24.tar.xz
- Source/build instructions: https://code.videolan.org/videolan/vlc/-/tree/3.0.24
- libVLC licensing: https://www.videolan.org/legal.html
- libVLC LGPL license: `VLC-COPYING.LIB.txt` in Coco's resources.
- VLC/plugin license text: `player/COPYING.txt`.

VideoLAN, VLC and dependency authors retain their copyrights and licenses.
The manifest pins every distributed runtime file by SHA-256. These are
upstream files; no claim of Windows Authenticode signing is made. Native
decoder sessions and frame buffers are released when playback closes. The
verified library modules remain loaded until Coco exits.
