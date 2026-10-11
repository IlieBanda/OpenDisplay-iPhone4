# OpenDisplay receiver for iPhone 4 / iOS 6

Research date: 2026-10-11. Upstream checked out in `upstream/` at
`b9eec1f232fb5ea571c87e8392379a84f47b237f`.

## Findings

- Receiver listens on TCP 9000 and publishes `_opensidecar._tcp` with a stable UUID and protocol version in TXT. Mac connects to it.
- Both directions use a 4-byte big-endian payload length. Reads must handle fragmented and combined messages.
- Send `hello` first and `ping` approximately every 2 seconds. Unknown JSON types/fields are ignored.
- Video is one H.264 Annex B access unit per message, with 4-byte start codes. Skip the optional JSON telemetry preceding the first start code. IDRs include SPS/PPS. Rebuild decoder on parameter-set changes; request recovery with `kf`.
- Touch uses normalized video coordinates; scroll uses video pixel deltas. Cursor overlays are an optional separate feature.
- Current sender sets `kVTProfileLevel_H264_High_AutoLevel` in `Mac/MacSender.swift`. Existing `videoCaps` negotiates codec, raster and rate, but not H.264 profile/level. A legacy hardware decoder path should be tested with Main/Baseline Level 3.1; initially this appeared to require a sender change. Physical testing demonstrated that this device decodes High@3.2, so no sender modification was needed.
- Apple's iPhone 4 specification advertises H.264 up to 720p30 Main Profile Level 3.1 in media files. This is not a guarantee that an arbitrary raw-stream decoder works.
- Current SDK declares public VT decompression and AVSampleBufferDisplayLayer APIs available from iOS 8. The modern Swift/Network/Metal receiver cannot simply be deployment-targeted to iOS 6.
- Kodi 16.1 contains a legacy iOS VideoToolbox path, dynamic framework loading and a Fig format-description helper. This is implementation evidence for investigating jailbreak-era decoding, not proof on this particular phone.
- Host has Xcode 27. A separate legacy armv7 toolchain/SDK must be established before claiming an installable iOS 6 build.

## Proposed implementation

Objective-C/Objective-C++, UIKit, BSD sockets/GCD, NSNetService, and OpenGL ES 2 presentation. Native armv7 application; no modern Swift runtime dependency.

First prove hardware decoding on the physical phone with a small Main/Baseline H.264 clip and log framework symbols, decoder creation/output and actual decode time. Only then connect the full live transport. Use software FFmpeg decoding as a diagnostic fallback, with reduced raster/rate and measured performance.

Initial experiment: fixed landscape 960x640 panel, 30 FPS ceiling, H.264 only. A 480x320 lower-rate mode is a fallback experiment, not a measured performance promise. Start with WiFi discovery, video and liveness; then input, cursor, rotation and USB.

Do not drop arbitrary encoded P-frames to shorten queues: subsequent frames can depend on them. Bound queues, continue decoding while skipping presentation where feasible, or resynchronize at an IDR using `kf`.

## References

- https://github.com/peetzweg/opendisplay/blob/main/PROTOCOL.md
- `upstream/Shared/StreamReceiver.swift`
- `upstream/Mac/MacSender.swift`
- https://support.apple.com/en-il/112562
- https://github.com/xbmc/xbmc/blob/16.1-Jarvis/xbmc/cores/dvdplayer/DVDCodecs/Video/DVDVideoCodecVideoToolBox.cpp

The native receiver has now been built and installed on iPhone3,1 / iOS 6.1.3. See docs/DEVICE-TESTS.md. The initial plan above is historical: the current renderer uses BGRA zero-copy texture-cache presentation at full 960x640/60, without a mode selector. Hardware-property introspection is unavailable; successful legacy VT output alone is not asserted as proof of the hardware property.
