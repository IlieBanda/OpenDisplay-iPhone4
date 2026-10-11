# Physical device tests — 2026-10-11

iPhone3,1 (A4), jailbroken iOS 6.1.3. Each network test sent a moving H.264 testsrc2 pattern for **30 seconds**, no B frames. Wi-Fi tests used the local network. Sender test logs are local build artifacts.

| Path | Stream | Observed result |
|---|---|---|
| Original BGRA / USB | Main@3.1, 960×640, 30 FPS | About 30 decoded FPS |
| Original BGRA / USB | High@3.2, 960×640, 30 FPS | About 30 decoded FPS |
| Original BGRA / Wi-Fi | High@3.2, 960×640, 30 FPS | 900 received and decoded; 29.85–29.98 decoded FPS |
| Original BGRA / Wi-Fi | High@3.2, 960×640, 60 FPS | Approximately 48–53 presented FPS; cannot claim native 60 |
| NV12 / native render | High@3.2, 960×640, 60 FPS | Decode can reach 60; rendering does not sustain 60 |
| NV12 / 480×320 render, bounded 3-image queue | High@3.2, 480×320, 60 FPS | 1800/1800 received and decoded; steady windows 58.8–59.6 presented FPS |

The first/last reporting windows include startup/teardown and can be lower. Frame counts measure images submitted for GLES presentation, not an optical measurement of screen refresh. Decode duration is the last call, not a median or end-to-end latency. Hardware acceleration property returns -12900 (unavailable) on this legacy OS.

The bundled decoder self-test previously completed 900/900 images over 30 seconds. Host wire parser passed ASan/UBSan checks for fragmentation, coalescing, bounds, demux, Annex B, SPS and malformed-input fuzzing. All Objective-C files compile in ARM mode to avoid modern-linker Thumb relocation failures.

The installed official Mac sender connected without modification. The user confirmed live desktop broadcast. A static desktop can produce very few frames because screen capture is change-driven; use moving content to assess frame rate.

Final smooth-mode rerun: 1800 received/decoded, 1733 presented images over the complete stream. Five-second windows were about 55–59 FPS, with occasional Wi-Fi/processing jitter. Thus this is a **60 FPS target mode**, not a guarantee of 60 unique presentations every second. Native 960×640 at 60 is not offered as a sustained mode.

The user confirmed the new rounded, glossy official icon after a SpringBoard restart.

Final quality-mode rerun: 900/900 received and decoded over 30 seconds; five-second presentation windows approximately 29.2–30.0 FPS. Both capability handshakes advertise their respective resolution/rate budget. Normal receiver port 9000 restored after tests.

Compatibility follow-up: the official sender's 480×320 stream advertised 16 reference frames and legacy VT creation failed (-12911), including alternate output formats. The final smooth mode therefore retains a 960×640 encoded stream while rendering to a 480×320 drawable. Official 958×640 → 960×640 streams created NV12 decoder sessions successfully and presented images. Quality mode renders the same dimensions at full panel resolution with a 30 FPS ceiling.

Final 960×640 input / 480×320 render / 60 FPS target, Wi-Fi, 30 seconds: 1800/1800 received and decoded; telemetry at the end reported 1718 submitted presentations. Steady five-second presentation windows: 58.96, 59.20, 58.22, 55.75, 59.91 FPS; initial window 51.13 FPS. Log: build/device-final-native-input60.log. This result supports a near-60 mode with occasional dropped presentations, rather than an exact 60 FPS guarantee.

## Current version 0.3 — full native resolution, no mode selection

BGRA zero-copy texture-cache rendering at **960×640 drawable resolution**, Wi-Fi,
High@3.2, 60 FPS input, 30 seconds: **1800 received, 1800 decoded, 1773 submitted
presentations**. Steady five-second windows: 60.01, 59.59, 59.78, 58.73, 59.71 FPS.
Startup window 54.51 FPS. Log build/device-native-bgra-cache60.log.
The earlier reduced-resolution modes above are historical experiments and are removed.
Both Bonjour and hello now identify the receiver as iPhone 4. The receiver starts
on foreground activation and stays listening after disconnect. No menu or manual
start button is exposed. Screen lock/home suspends reception, per the user's request.

Final foreground rerun, build/device-final-full60.log: native 960×640 BGRA texture-cache
presentation, 30 seconds at 60 FPS input; 1800 received, decoded and presented.
Five-second windows after startup were approximately 59.2–60.0 FPS. A startup backlog
was drained before disconnect; this does not establish an exact 16.67 ms presentation
interval or optical end-to-end latency.

The user reported a frozen screen, recovered after stopping the receiver and restarting
SpringBoard. The crash log separately showed dead10cc for a suspended process holding
com.apple.opengl/shaders.maps. Releasing view/context resources alone did not prevent
the legacy driver lock. UIApplicationExitsOnSuspend is now enabled so leaving the
foreground terminates normally. A Settings transition then produced no new crash report,
and normal reopening succeeded. Apple documents this legacy flag in its archived
[Info.plist reference](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/iPhoneOSKeys.html).

The readiness screen was captured on the physical device and visually inspected:
build/ready-ios6.png. Native renderer, no menu/buttons, automatic listening, stable
identity with display name iPhone 4. Normal port 9000 restored after testing.

Final official sender check: UI identifies iPhone 4 over Wi-Fi, quality Best unchanged.
Reconnected only this receiver; Other receiver connections were preserved.
Official 958×640 → 960×640 High@3.2/60 sessions created BGRA decoder output and
presented on a 960×640 drawable. Connection remained up for another 30 seconds.
The desktop was static, so its observed image rate was low and is not a live-video
60 FPS performance measurement.

## Version 0.4 — portrait rotation

UI orientation supports portrait, upside-down portrait and both landscape directions.
Layout changes update panel facts and both decode ceilings through a fresh hello on
the live TCP connection, per upstream PROTOCOL.md section 6.1. SPS limits now allow
either 960×640 or 640×960, preserving the same pixel budget.

Physical portrait test, 640×960 High@3.2 / 60 FPS input over Wi-Fi for 30 seconds:
1800 received, 1800 decoded, 1770 presented. BGRA zero-copy drawable confirmed
640×960. Steady presentation windows approximately 58.6–59.8 FPS.
Log: build/device-portrait60.log.

Physical rotation follow-up: UIKit delivered orientation changes and new hello
messages were acknowledged, but macOS rejected the sender Retina virtual-display
resize and rolled back to portrait, producing a 426×640 stream that failed legacy
VT creation. Selected Native (1x) through the official sender display-size control
for iPhone 4 only. The user then confirmed both rotation directions work correctly.
No sender source or other devices settings were changed. Screenshots captured from
the physical device via UIGetScreenImage: build/iphone4-current.png (before fix),
build/iphone4-rotation-fixed.png (after fix).

## Touch handling parity

Official OpenSidecarPhoneApp.swift holds pending finger down until tap release,
120 ms deliberate hold, or >10 UIKit points of movement. The old iPhone and
Switch clients sent began immediately, turning finger jitter into mouse drag.
The iPhone implementation now follows the official deferred-down policy, including
cancelling pending down for two-finger scroll and preserving deliberate hold/drag.
Switch sources were inspected read-only and remain unchanged. Physical tap/drag/
scroll verification requested from the user for 30 seconds.

The user confirmed deferred-down touch handling works very well on iPhone 4.
Then both scroll components were negated at the wire boundary at the user request;
updated build installed and reopened. Switch migration notes: docs/SWITCH-TOUCH-FIX.md.
